-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_038.sql
-- Self sign-ups are locked until the CEO / HR approves them in the
-- system. A new account lands with is_active = false and
-- approval_status = 'pending'; every app refuses it until approved.
-- Accounts created by HR through "Create login" are approved at once.
-- Pre-registered invites (email matched) are also approved at once,
-- since HR already vetted them.
-- ADDITIVE ONLY. Run once, after 037.
-- =====================================================================

alter table public.app_users add column if not exists approval_status text not null default 'approved'
  check (approval_status in ('pending','approved','rejected'));
alter table public.app_users add column if not exists approved_by uuid references public.app_users(id);
alter table public.app_users add column if not exists approved_at timestamptz;

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  inv      public.user_invites%rowtype;
  is_first boolean;
  by_admin boolean;
begin
  select * into inv from public.user_invites
   where lower(email) = lower(new.email) and consumed_at is null
   limit 1;
  select count(*) = 0 into is_first from public.app_users;
  -- created through the admin API (HR "Create login") -> trusted
  by_admin := coalesce(new.raw_app_meta_data->>'provider', '') = 'email' and new.email_confirmed_at is not null and new.confirmation_sent_at is null;

  insert into public.app_users (id, email, full_name_en, full_name_ar, role, branch_id, is_active, approval_status, approved_at)
  values (
    new.id,
    new.email,
    coalesce(inv.full_name_en, new.raw_user_meta_data->>'full_name_en', split_part(new.email,'@',1)),
    coalesce(inv.full_name_ar, new.raw_user_meta_data->>'full_name_ar'),
    case when is_first then 'ceo' else coalesce(inv.role, 'staff') end,
    inv.branch_id,
    (is_first or inv.id is not null or by_admin),
    case when (is_first or inv.id is not null or by_admin) then 'approved' else 'pending' end,
    case when (is_first or inv.id is not null or by_admin) then now() end
  )
  on conflict (id) do nothing;

  if inv.id is not null then
    update public.user_invites set consumed_at = now() where id = inv.id;
  end if;
  return new;
end;
$fn$;

-- the maintenance / CRM login resolver ignores unapproved accounts
create or replace function public.hv_login_email(p_username text)
returns text language sql stable security definer set search_path = public as $fn$
  select coalesce(
    (select a.email from public.app_users a where lower(a.username) = lower(p_username) and a.is_active and a.approval_status = 'approved' limit 1),
    (select u.email from public.hv_users u join public.app_users a on a.id = u.auth_user_id
      where lower(u.username) = lower(p_username) and u.is_active and a.is_active and a.approval_status = 'approved' limit 1),
    (select au.email from public.profiles p join auth.users au on au.id = p.id join public.app_users a on a.id = p.id
      where lower(p.username) = lower(p_username) and a.is_active and a.approval_status = 'approved' limit 1),
    (select a.email from public.app_users a where lower(a.email) = lower(p_username) and a.is_active and a.approval_status = 'approved' limit 1))
$fn$;
grant execute on function public.hv_login_email(text) to anon, authenticated;

-- a pending account must not be provisioned into the other systems
create or replace function public.sync_system_access()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  v_name    text;
  v_emp     uuid;
  v_uname   text;
  v_init    text;
  v_hvrole  text;
  v_crmrole text;
  n int;
  live boolean;
begin
  live := new.is_active and new.approval_status = 'approved';
  v_name := coalesce(nullif(new.full_name_ar, ''), nullif(new.full_name_en, ''), split_part(new.email, '@', 1));
  select id into v_emp from public.employees where user_id = new.id limit 1;
  v_uname := coalesce(nullif(new.username, ''), split_part(new.email, '@', 1));
  v_init  := upper(left(regexp_replace(coalesce(new.full_name_en, v_uname), '[^A-Za-z]', '', 'g'), 2));
  if v_init = '' then v_init := 'HV'; end if;
  v_hvrole := case new.role when 'ceo' then 'ceo' when 'accountant' then 'accountant'
                            when 'hr' then 'admin' when 'manager' then 'admin' else 'employee' end;
  v_crmrole := case new.role when 'ceo' then 'ceo' when 'accountant' then 'accountant'
                             when 'hr' then 'admin' when 'manager' then 'manager' else 'staff' end;

  if new.access_maint and live then
    if exists (select 1 from public.hv_users where auth_user_id = new.id) then
      update public.hv_users set is_active = true, email = new.email, employee_id = coalesce(employee_id, v_emp) where auth_user_id = new.id;
    elsif exists (select 1 from public.hv_users where lower(username) = lower(v_uname) and auth_user_id is null) then
      update public.hv_users set auth_user_id = new.id, is_active = true, email = new.email, employee_id = coalesce(employee_id, v_emp)
       where lower(username) = lower(v_uname) and auth_user_id is null;
    else
      n := 1;
      while exists (select 1 from public.hv_users where lower(username) = lower(v_uname || case when n = 1 then '' else n::text end)) loop n := n + 1; end loop;
      insert into public.hv_users (name, username, password, role, avatar, auth_user_id, email, employee_id, is_active)
      values (v_name, v_uname || case when n = 1 then '' else n::text end, '(unified login)', v_hvrole, v_init, new.id, new.email, v_emp, true);
    end if;
  else
    update public.hv_users set is_active = false where auth_user_id = new.id and is_active;
  end if;

  if new.access_crm and live then
    if exists (select 1 from public.profiles where id = new.id) then
      update public.profiles set is_active = true, employee_id = coalesce(employee_id, v_emp) where id = new.id;
    else
      n := 1;
      while exists (select 1 from public.profiles where lower(username) = lower(v_uname || case when n = 1 then '' else n::text end)) loop n := n + 1; end loop;
      insert into public.profiles (id, username, name, role, permissions, is_active, employee_id)
      values (new.id, v_uname || case when n = 1 then '' else n::text end, v_name, v_crmrole, '[]'::jsonb, true, v_emp);
    end if;
  else
    update public.profiles set is_active = false where id = new.id and is_active;
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_sync_system_access on public.app_users;
create trigger trg_sync_system_access
  after insert or update of access_hr, access_maint, access_crm, username, email, full_name_en, full_name_ar, is_active, approval_status on public.app_users
  for each row execute function public.sync_system_access();

-- role helper: a pending account has no role anywhere (RLS treats it as nobody)
create or replace function public.my_role()
returns text language sql stable security definer set search_path = public as $fn$
  select role from public.app_users where id = auth.uid() and is_active and approval_status = 'approved'
$fn$;
