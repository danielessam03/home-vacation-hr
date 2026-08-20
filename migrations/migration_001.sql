-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_001.sql
-- Module 1: Auth, users/roles, branches, holidays, work week,
--           Egyptian income tax brackets, social insurance rates,
--           audit log foundation.
--
-- ADDITIVE ONLY. Run once in the Supabase SQL editor.
-- Nothing here DROPs a table or deletes data.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------
-- 1. updated_at helper
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $fn$
begin
  new.updated_at = now();
  return new;
end;
$fn$;

-- ---------------------------------------------------------------------
-- 2. Branches
-- ---------------------------------------------------------------------
create table if not exists public.branches (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,
  name_en      text not null,
  name_ar      text not null,
  address      text,
  phone        text,
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

drop trigger if exists trg_branches_touch on public.branches;
create trigger trg_branches_touch before update on public.branches
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 3. Application users (1:1 with auth.users)
--    Roles: ceo | hr | accountant | manager | staff
-- ---------------------------------------------------------------------
create table if not exists public.app_users (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text not null,
  full_name_en  text,
  full_name_ar  text,
  role          text not null default 'staff'
                check (role in ('ceo','hr','accountant','manager','staff')),
  branch_id     uuid references public.branches(id),
  phone         text,
  lang          text not null default 'ar' check (lang in ('ar','en')),
  is_active     boolean not null default true,
  last_login_at timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists idx_app_users_role   on public.app_users(role);
create index if not exists idx_app_users_branch on public.app_users(branch_id);
create index if not exists idx_app_users_email  on public.app_users(lower(email));

drop trigger if exists trg_app_users_touch on public.app_users;
create trigger trg_app_users_touch before update on public.app_users
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 4. Role helpers -- SECURITY DEFINER so they bypass RLS on app_users.
--    This is what prevents "infinite recursion detected in policy".
--    NEVER query app_users directly inside an app_users policy.
-- ---------------------------------------------------------------------
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $fn$
  select role from public.app_users where id = auth.uid() and is_active
$fn$;

create or replace function public.my_branch()
returns uuid language sql stable security definer set search_path = public as $fn$
  select branch_id from public.app_users where id = auth.uid() and is_active
$fn$;

create or replace function public.has_role(variadic roles text[])
returns boolean language sql stable security definer set search_path = public as $fn$
  select coalesce(public.my_role() = any(roles), false)
$fn$;

grant execute on function public.my_role()        to authenticated;
grant execute on function public.my_branch()      to authenticated;
grant execute on function public.has_role(text[]) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Pre-registration invites.
--    HR records email + role BEFORE the person signs up; the auth trigger
--    below picks it up so the new account lands with the right role.
-- ---------------------------------------------------------------------
create table if not exists public.user_invites (
  id           uuid primary key default gen_random_uuid(),
  email        text not null unique,
  role         text not null default 'staff'
               check (role in ('ceo','hr','accountant','manager','staff')),
  branch_id    uuid references public.branches(id),
  full_name_en text,
  full_name_ar text,
  consumed_at  timestamptz,
  created_by   uuid references public.app_users(id),
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. Auto-create the app_users row when someone signs up
-- ---------------------------------------------------------------------
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  inv      public.user_invites%rowtype;
  is_first boolean;
begin
  select * into inv from public.user_invites
   where lower(email) = lower(new.email) and consumed_at is null
   limit 1;

  -- The very first account ever created becomes the CEO, so you are
  -- never locked out of a fresh database.
  select count(*) = 0 into is_first from public.app_users;

  insert into public.app_users (id, email, full_name_en, full_name_ar, role, branch_id)
  values (
    new.id,
    new.email,
    coalesce(inv.full_name_en, new.raw_user_meta_data->>'full_name_en', split_part(new.email,'@',1)),
    coalesce(inv.full_name_ar, new.raw_user_meta_data->>'full_name_ar'),
    case when is_first then 'ceo' else coalesce(inv.role, 'staff') end,
    inv.branch_id
  )
  on conflict (id) do nothing;

  if inv.id is not null then
    update public.user_invites set consumed_at = now() where id = inv.id;
  end if;

  return new;
end;
$fn$;

drop trigger if exists trg_on_auth_user_created on auth.users;
create trigger trg_on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- ---------------------------------------------------------------------
-- 7. Official holidays
-- ---------------------------------------------------------------------
create table if not exists public.holidays (
  id           uuid primary key default gen_random_uuid(),
  holiday_date date not null,
  name_en      text not null,
  name_ar      text not null,
  is_paid      boolean not null default true,
  branch_id    uuid references public.branches(id),   -- null = all branches
  created_at   timestamptz not null default now(),
  unique (holiday_date, branch_id)
);
create index if not exists idx_holidays_date on public.holidays(holiday_date);

-- ---------------------------------------------------------------------
-- 8. Key/value app settings (work week, company profile, policies)
-- ---------------------------------------------------------------------
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null default '{}'::jsonb,
  updated_by uuid references public.app_users(id),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_app_settings_touch on public.app_settings;
create trigger trg_app_settings_touch before update on public.app_settings
  for each row execute function public.touch_updated_at();

-- weekend_days uses JS/Postgres day numbering: 0=Sun .. 5=Fri, 6=Sat
insert into public.app_settings (key, value) values
  ('work_week', jsonb_build_object(
      'weekend_days', jsonb_build_array(5,6),
      'standard_hours_per_day', 8,
      'standard_days_per_month', 30
   )),
  ('company', jsonb_build_object(
      'name_en', 'Home Vacation',
      'name_ar', 'هوم فاكيشن',
      'city', 'Hurghada',
      'country', 'Egypt',
      'currency', 'EGP',
      'tax_file_no', '',
      'nosi_office', ''
   ))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 9. Egyptian income tax -- editable annual brackets.
--    Seeded with the 2025 schedule. VERIFY WITH YOUR ACCOUNTANT and edit
--    in Settings; the app always reads this table, never hardcodes rates.
-- ---------------------------------------------------------------------
create table if not exists public.tax_brackets (
  id             uuid primary key default gen_random_uuid(),
  effective_from date not null,
  seq            int  not null,
  lower_bound    numeric(14,2) not null,
  upper_bound    numeric(14,2),          -- null = no ceiling
  rate           numeric(6,4)  not null, -- 0.10 = 10%
  created_at     timestamptz not null default now(),
  unique (effective_from, seq)
);

create table if not exists public.tax_settings (
  id                        uuid primary key default gen_random_uuid(),
  effective_from            date not null unique,
  personal_exemption_annual numeric(14,2) not null default 20000,
  notes                     text,
  created_at                timestamptz not null default now()
);

insert into public.tax_settings (effective_from, personal_exemption_annual, notes)
values (date '2025-01-01', 20000, 'Annual personal exemption. Editable in Settings.')
on conflict (effective_from) do nothing;

insert into public.tax_brackets (effective_from, seq, lower_bound, upper_bound, rate) values
  (date '2025-01-01', 1,       0,    40000, 0.0000),
  (date '2025-01-01', 2,   40000,    55000, 0.1000),
  (date '2025-01-01', 3,   55000,    70000, 0.1500),
  (date '2025-01-01', 4,   70000,   200000, 0.2000),
  (date '2025-01-01', 5,  200000,   400000, 0.2250),
  (date '2025-01-01', 6,  400000,  1200000, 0.2500),
  (date '2025-01-01', 7, 1200000,     null, 0.2750)
on conflict (effective_from, seq) do nothing;

-- ---------------------------------------------------------------------
-- 10. Social insurance rates + wage floor/ceiling (editable)
-- ---------------------------------------------------------------------
create table if not exists public.insurance_rates (
  id                 uuid primary key default gen_random_uuid(),
  effective_from     date not null unique,
  employer_rate      numeric(6,4) not null default 0.1875,  -- 18.75%
  employee_rate      numeric(6,4) not null default 0.1100,  -- 11%
  min_insurance_wage numeric(14,2) not null default 2300,   -- monthly EGP
  max_insurance_wage numeric(14,2) not null default 14500,  -- monthly EGP
  notes              text,
  created_at         timestamptz not null default now()
);

insert into public.insurance_rates
  (effective_from, employer_rate, employee_rate, min_insurance_wage, max_insurance_wage, notes)
values
  (date '2025-01-01', 0.1875, 0.1100, 2300, 14500,
   'Employer 18.75% / employee 11%. Verify the wage floor and ceiling each January.')
on conflict (effective_from) do nothing;

-- ---------------------------------------------------------------------
-- 11. Audit log (expanded further in module 7)
-- ---------------------------------------------------------------------
create table if not exists public.audit_log (
  id          bigserial primary key,
  actor_id    uuid references public.app_users(id),
  actor_email text,
  actor_role  text,
  action      text not null,   -- insert | update | delete | approve | lock | login
  entity      text not null,   -- table or module name
  entity_id   text,
  before_data jsonb,
  after_data  jsonb,
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_audit_entity  on public.audit_log(entity, entity_id);
create index if not exists idx_audit_created on public.audit_log(created_at desc);

-- ---------------------------------------------------------------------
-- 12. Row Level Security
-- ---------------------------------------------------------------------
alter table public.branches        enable row level security;
alter table public.app_users       enable row level security;
alter table public.user_invites    enable row level security;
alter table public.holidays        enable row level security;
alter table public.app_settings    enable row level security;
alter table public.tax_brackets    enable row level security;
alter table public.tax_settings    enable row level security;
alter table public.insurance_rates enable row level security;
alter table public.audit_log       enable row level security;

-- app_users -----------------------------------------------------------
drop policy if exists app_users_select on public.app_users;
create policy app_users_select on public.app_users for select to authenticated
  using ( id = auth.uid() or public.has_role('ceo','hr','accountant','manager') );

drop policy if exists app_users_update_self on public.app_users;
create policy app_users_update_self on public.app_users for update to authenticated
  using ( id = auth.uid() ) with check ( id = auth.uid() );

drop policy if exists app_users_admin_write on public.app_users;
create policy app_users_admin_write on public.app_users for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- reference data: everyone reads, ceo/hr writes ------------------------
drop policy if exists branches_read on public.branches;
create policy branches_read on public.branches for select to authenticated using (true);
drop policy if exists branches_write on public.branches;
create policy branches_write on public.branches for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

drop policy if exists holidays_read on public.holidays;
create policy holidays_read on public.holidays for select to authenticated using (true);
drop policy if exists holidays_write on public.holidays;
create policy holidays_write on public.holidays for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

drop policy if exists settings_read on public.app_settings;
create policy settings_read on public.app_settings for select to authenticated using (true);
drop policy if exists settings_write on public.app_settings;
create policy settings_write on public.app_settings for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- tax + insurance: everyone reads (payslips need it), ceo/hr/accountant writes
drop policy if exists tax_brackets_read on public.tax_brackets;
create policy tax_brackets_read on public.tax_brackets for select to authenticated using (true);
drop policy if exists tax_brackets_write on public.tax_brackets;
create policy tax_brackets_write on public.tax_brackets for all to authenticated
  using ( public.has_role('ceo','hr','accountant') ) with check ( public.has_role('ceo','hr','accountant') );

drop policy if exists tax_settings_read on public.tax_settings;
create policy tax_settings_read on public.tax_settings for select to authenticated using (true);
drop policy if exists tax_settings_write on public.tax_settings;
create policy tax_settings_write on public.tax_settings for all to authenticated
  using ( public.has_role('ceo','hr','accountant') ) with check ( public.has_role('ceo','hr','accountant') );

drop policy if exists insurance_rates_read on public.insurance_rates;
create policy insurance_rates_read on public.insurance_rates for select to authenticated using (true);
drop policy if exists insurance_rates_write on public.insurance_rates;
create policy insurance_rates_write on public.insurance_rates for all to authenticated
  using ( public.has_role('ceo','hr','accountant') ) with check ( public.has_role('ceo','hr','accountant') );

-- invites -------------------------------------------------------------
drop policy if exists invites_admin on public.user_invites;
create policy invites_admin on public.user_invites for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- audit log: append-only. No update/delete policy exists, so nobody can
-- rewrite history through the API -- not even the CEO.
drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log for select to authenticated
  using ( public.has_role('ceo','hr','accountant') );
drop policy if exists audit_insert on public.audit_log;
create policy audit_insert on public.audit_log for insert to authenticated
  with check ( actor_id = auth.uid() );

-- ---------------------------------------------------------------------
-- 13. Seed one branch so the app is usable immediately
-- ---------------------------------------------------------------------
insert into public.branches (code, name_en, name_ar, address)
values ('HRG-HO', 'Hurghada Head Office', 'الغردقة - المركز الرئيسي', 'Hurghada, Red Sea')
on conflict (code) do nothing;
