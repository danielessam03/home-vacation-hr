-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_007.sql
-- Module 5: payroll runs per branch/month with draft -> accountant
--           review -> CEO approval -> locked; per-employee payslip
--           items with a full calculation snapshot; payroll policy.
--
-- ADDITIVE ONLY. Run once, after 006.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Editable payroll policy (multipliers used by the calculator)
-- ---------------------------------------------------------------------
insert into public.app_settings (key, value) values
  ('payroll_policy', jsonb_build_object(
     'ot_multiplier', 1.35,        -- overtime hourly multiplier (law: 135% day)
     'late_multiplier', 1.0        -- late minutes deducted at this multiple
   ))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 2. Payroll runs
-- ---------------------------------------------------------------------
create table if not exists public.payroll_runs (
  id           uuid primary key default gen_random_uuid(),
  year         int not null,
  month        int not null check (month between 1 and 12),
  branch_id    uuid not null references public.branches(id),
  status       text not null default 'draft'
               check (status in ('draft','review','approved')),
  created_by   uuid references public.app_users(id),
  submitted_by uuid references public.app_users(id),
  submitted_at timestamptz,
  approved_by  uuid references public.app_users(id),
  approved_at  timestamptz,
  notes        text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (year, month, branch_id)
);

drop trigger if exists trg_payroll_runs_touch on public.payroll_runs;
create trigger trg_payroll_runs_touch before update on public.payroll_runs
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 3. Payroll items (one per employee per run) -- a frozen snapshot of
--    every number that made up the payslip.
-- ---------------------------------------------------------------------
create table if not exists public.payroll_items (
  id                   uuid primary key default gen_random_uuid(),
  run_id               uuid not null references public.payroll_runs(id) on delete cascade,
  employee_id          uuid not null references public.employees(id),
  basic_salary         numeric(14,2) not null default 0,
  allowances           jsonb not null default '[]'::jsonb,
  allowances_total     numeric(14,2) not null default 0,
  ot_minutes           int not null default 0,
  ot_amount            numeric(14,2) not null default 0,
  other_earnings       numeric(14,2) not null default 0,
  other_earnings_note  text,
  late_minutes         int not null default 0,
  late_deduction       numeric(14,2) not null default 0,
  unpaid_days          numeric(6,2) not null default 0,
  unpaid_deduction     numeric(14,2) not null default 0,
  sick_days            numeric(6,2) not null default 0,
  sick_deduction       numeric(14,2) not null default 0,
  other_deductions     numeric(14,2) not null default 0,
  other_deductions_note text,
  insurance_base       numeric(14,2) not null default 0,
  insurance_employee   numeric(14,2) not null default 0,
  insurance_employer   numeric(14,2) not null default 0,
  income_tax           numeric(14,2) not null default 0,
  gross_pay            numeric(14,2) not null default 0,   -- basic+allow+ot+other earnings
  total_deductions     numeric(14,2) not null default 0,
  net_pay              numeric(14,2) not null default 0,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  unique (run_id, employee_id)
);
create index if not exists idx_payroll_items_run on public.payroll_items(run_id);
create index if not exists idx_payroll_items_emp on public.payroll_items(employee_id);

drop trigger if exists trg_payroll_items_touch on public.payroll_items;
create trigger trg_payroll_items_touch before update on public.payroll_items
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 4. Hard lock: an approved run can never be changed, and its items can
--    never be touched -- enforced in the database, binding on everyone.
--    Draft runs may be deleted; anything further along may not.
-- ---------------------------------------------------------------------
create or replace function public.check_payroll_item_lock()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare st text;
begin
  select status into st from public.payroll_runs where id = coalesce(new.run_id, old.run_id);
  if st = 'approved' then
    raise exception 'PAYROLL_LOCKED: this payroll run is approved and locked';
  end if;
  return coalesce(new, old);
end;
$fn$;

drop trigger if exists trg_payroll_item_lock on public.payroll_items;
create trigger trg_payroll_item_lock before insert or update or delete on public.payroll_items
  for each row execute function public.check_payroll_item_lock();

create or replace function public.check_payroll_run_lock()
returns trigger language plpgsql as $fn$
begin
  if tg_op = 'UPDATE' and old.status = 'approved' then
    raise exception 'PAYROLL_LOCKED: approved runs cannot be modified';
  end if;
  if tg_op = 'DELETE' and old.status <> 'draft' then
    raise exception 'PAYROLL_LOCKED: only draft runs can be deleted';
  end if;
  return coalesce(new, old);
end;
$fn$;

drop trigger if exists trg_payroll_run_lock on public.payroll_runs;
create trigger trg_payroll_run_lock before update or delete on public.payroll_runs
  for each row execute function public.check_payroll_run_lock();

-- ---------------------------------------------------------------------
-- 5. Row Level Security
--    accountant + ceo build and edit payroll; hr sees it (per the role
--    spec: hr = everything except payroll approval); an employee sees
--    only their own items from approved runs (self-service payslips).
-- ---------------------------------------------------------------------
alter table public.payroll_runs  enable row level security;
alter table public.payroll_items enable row level security;

drop policy if exists payroll_runs_select on public.payroll_runs;
create policy payroll_runs_select on public.payroll_runs for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or (status = 'approved' and exists (
      select 1 from public.payroll_items i
       where i.run_id = payroll_runs.id and i.employee_id = public.my_employee_id()))
  );

drop policy if exists payroll_runs_write on public.payroll_runs;
create policy payroll_runs_write on public.payroll_runs for all to authenticated
  using ( public.has_role('ceo','accountant') ) with check ( public.has_role('ceo','accountant') );

drop policy if exists payroll_items_select on public.payroll_items;
create policy payroll_items_select on public.payroll_items for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or (employee_id = public.my_employee_id() and exists (
      select 1 from public.payroll_runs r
       where r.id = payroll_items.run_id and r.status = 'approved'))
  );

drop policy if exists payroll_items_write on public.payroll_items;
create policy payroll_items_write on public.payroll_items for all to authenticated
  using ( public.has_role('ceo','accountant') ) with check ( public.has_role('ceo','accountant') );
