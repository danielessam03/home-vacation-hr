-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_018.sql
-- One login per person, managed from HR:
--   * app_users.username  -- the single username that opens every system
--   * app_users.access_hr / access_maint / access_crm -- which systems the
--     person may enter (checkboxes in HR). A trigger provisions or
--     suspends the matching maintenance (hv_users) and CRM (profiles)
--     rows, so the other two apps keep their own tables untouched.
--   * profiles.is_active -- CRM access can be switched off without
--     deleting the profile (role/permissions survive)
--   * hv_login_email() now resolves the HR username first
--   * terminating an employee suspends all three systems; reactivating
--     restores exactly the systems that were ticked
-- ADDITIVE ONLY. Run once, after 017.
-- =====================================================================

alter table public.app_users add column if not exists username     text;
alter table public.app_users add column if not exists access_hr    boolean not null default true;
alter table public.app_users add column if not exists access_maint boolean not null default false;
alter table public.app_users add column if not exists access_crm   boolean not null default false;
create unique index if not exists uq_app_users_username on public.app_users (lower(username)) where username is not null;

alter table public.profiles add column if not exists is_active boolean not null default true;

-- ---------------------------------------------------------------------
-- 1. Backfill: username = maintenance username (the one people type every
--    day) > CRM username > the part of the email before @. Collisions get
--    a numeric suffix.
-- ---------------------------------------------------------------------
do $b$
declare r record; base text; cand text; n int;
begin
  for r in select a.id, a.email,
                  (select h.username from public.hv_users h where h.auth_user_id = a.id order by h.is_active desc, h.id limit 1) as hv_u,
                  (select p.username from public.profiles p where p.id = a.id) as crm_u
             from public.app_users a where a.username is null order by a.created_at
  loop
    base := coalesce(nullif(trim(r.hv_u), ''), nullif(trim(r.crm_u), ''), split_part(r.email, '@', 1));
    cand := base; n := 1;
    while exists (select 1 from public.app_users x where lower(x.username) = lower(cand) and x.id <> r.id) loop
      n := n + 1; cand := base || n::text;
    end loop;
    update public.app_users set username = cand where id = r.id;
  end loop;
end $b$;

-- current reality becomes the initial checkbox state
update public.app_users a set
  access_maint = exists (select 1 from public.hv_users h where h.auth_user_id = a.id and h.is_active),
  access_crm   = exists (select 1 from public.profiles p where p.id = a.id and p.is_active);

-- ---------------------------------------------------------------------
-- 2. Provisioning trigger: the checkboxes drive hv_users / profiles
-- ---------------------------------------------------------------------
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
begin
  v_name := coalesce(nullif(new.full_name_ar, ''), nullif(new.full_name_en, ''), split_part(new.email, '@', 1));
  select id into v_emp from public.employees where user_id = new.id limit 1;
  v_uname := coalesce(nullif(new.username, ''), split_part(new.email, '@', 1));
  v_init  := upper(left(regexp_replace(coalesce(new.full_name_en, v_uname), '[^A-Za-z]', '', 'g'), 2));
  if v_init = '' then v_init := 'HV'; end if;
  v_hvrole := case new.role when 'ceo' then 'ceo' when 'accountant' then 'accountant'
                            when 'hr' then 'admin' when 'manager' then 'admin' else 'employee' end;
  v_crmrole := case new.role when 'ceo' then 'ceo' when 'accountant' then 'accountant'
                             when 'hr' then 'admin' when 'manager' then 'manager' else 'staff' end;

  /* ---- maintenance system (hv_users) ---- */
  if new.access_maint then
    if exists (select 1 from public.hv_users where auth_user_id = new.id) then
      update public.hv_users set is_active = true, email = new.email,
             employee_id = coalesce(employee_id, v_emp)
       where auth_user_id = new.id;
    elsif exists (select 1 from public.hv_users where lower(username) = lower(v_uname) and auth_user_id is null) then
      -- an old, never-linked maintenance account with the same username: adopt it
      update public.hv_users set auth_user_id = new.id, is_active = true, email = new.email,
             employee_id = coalesce(employee_id, v_emp)
       where lower(username) = lower(v_uname) and auth_user_id is null;
    else
      n := 1;
      while exists (select 1 from public.hv_users where lower(username) = lower(v_uname || case when n = 1 then '' else n::text end)) loop
        n := n + 1;
      end loop;
      insert into public.hv_users (name, username, password, role, avatar, auth_user_id, email, employee_id, is_active)
      values (v_name, v_uname || case when n = 1 then '' else n::text end, '(unified login)', v_hvrole, v_init, new.id, new.email, v_emp, true);
    end if;
  else
    update public.hv_users set is_active = false where auth_user_id = new.id and is_active;
  end if;

  /* ---- CRM (profiles) ---- */
  if new.access_crm then
    if exists (select 1 from public.profiles where id = new.id) then
      update public.profiles set is_active = true, employee_id = coalesce(employee_id, v_emp) where id = new.id;
    else
      n := 1;
      while exists (select 1 from public.profiles where lower(username) = lower(v_uname || case when n = 1 then '' else n::text end)) loop
        n := n + 1;
      end loop;
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
  after insert or update of access_hr, access_maint, access_crm, username, email, full_name_en, full_name_ar on public.app_users
  for each row execute function public.sync_system_access();

-- linking an employee to a login later also stamps the employee on the
-- maintenance / CRM rows
create or replace function public.sync_employee_link()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.user_id is not null then
    update public.hv_users set employee_id = new.id where auth_user_id = new.user_id and employee_id is distinct from new.id;
    update public.profiles set employee_id = new.id where id = new.user_id and employee_id is distinct from new.id;
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_sync_employee_link on public.employees;
create trigger trg_sync_employee_link after insert or update of user_id on public.employees
  for each row execute function public.sync_employee_link();

-- ---------------------------------------------------------------------
-- 3. Login resolver: HR username first, then the legacy per-system names
-- ---------------------------------------------------------------------
create or replace function public.hv_login_email(p_username text)
returns text language sql stable security definer set search_path = public as $fn$
  select coalesce(
    (select a.email from public.app_users a where lower(a.username) = lower(p_username) and a.is_active limit 1),
    (select u.email from public.hv_users u where lower(u.username) = lower(p_username) and u.is_active and u.auth_user_id is not null limit 1),
    (select au.email from public.profiles p join auth.users au on au.id = p.id where lower(p.username) = lower(p_username) limit 1),
    (select a.email from public.app_users a where lower(a.email) = lower(p_username) and a.is_active limit 1))
$fn$;
grant execute on function public.hv_login_email(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Employee status: terminate = off everywhere; reactivate = restore
--    exactly what was ticked
-- ---------------------------------------------------------------------
create or replace function public.sync_employee_status()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.status = 'terminated' and (old.status is distinct from new.status) then
    update public.hv_users set is_active = false where employee_id = new.id or auth_user_id = new.user_id;
    update public.profiles set is_active = false where id = new.user_id;
    update public.app_users set is_active = false where id = new.user_id;
  elsif new.status = 'active' and old.status = 'terminated' then
    update public.app_users set is_active = true where id = new.user_id;
    update public.hv_users h set is_active = a.access_maint from public.app_users a where a.id = h.auth_user_id and a.id = new.user_id;
    update public.profiles p set is_active = a.access_crm from public.app_users a where a.id = p.id and a.id = new.user_id;
  end if;
  return new;
end;
$fn$;

-- ---------------------------------------------------------------------
-- 5. HR staff (ceo/hr) may read the CRM profile rows to show the link
-- ---------------------------------------------------------------------
drop policy if exists profiles_hr_read on public.profiles;
create policy profiles_hr_read on public.profiles for select to authenticated using (public.has_role('ceo','hr'));
