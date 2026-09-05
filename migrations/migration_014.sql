-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_014.sql
-- Integration, step 2: one identity across the three systems.
--   * hv_users (maintenance) and profiles (CRM) linked to auth users and
--     to HR employee records
--   * hv_login_email(): lets the maintenance app keep its username login
--     while authenticating through the unified Supabase Auth
--   * employee status drives the other systems (terminate once, off everywhere)
-- ADDITIVE ONLY. Run once, after 013.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Link maintenance users to their unified login (by the migration map)
-- ---------------------------------------------------------------------
update public.hv_users u set auth_user_id = m.uid, email = m.email
from (values
  (1,  'be494a0f-9795-402d-851f-d7ce55fc896b'::uuid, 'essam@hv-crm.local'),
  (2,  'b1a092d4-2395-411d-a3f4-99682ba1ed47'::uuid, 'dalia.afifi@hv.local'),
  (3,  '1e469040-1374-4b5a-afbe-1cb14db280da'::uuid, 'admin@hv-crm.local'),
  (5,  'a113ef51-4230-405e-a54b-0c579b5ccb99'::uuid, 'micheal.nabil@hv.local'),
  (17, 'ce6f6776-c522-48c0-bab9-5d6bf91b6a17'::uuid, 'accounting@hv-crm.local'),
  (18, '9918defa-d49c-49c0-930a-020c39916cc5'::uuid, 'accounting1@hv-crm.local'),
  (19, 'd6cce767-1e76-46cc-ae23-170cb9f28628'::uuid, 'd.essam@home-vacation.com')
) as m(id, uid, email)
where u.id = m.id and u.auth_user_id is null;

-- ---------------------------------------------------------------------
-- 2. Link logins to HR employee records where the person already exists
--    (Hany Wagih = device 6, Ishaak/Esak Gayed = device 14, Daniel = HV-CEO)
-- ---------------------------------------------------------------------
update public.employees set user_id = '1e469040-1374-4b5a-afbe-1cb14db280da' where device_code = '6'  and user_id is null;
update public.employees set user_id = 'ce6f6776-c522-48c0-bab9-5d6bf91b6a17' where device_code = '14' and user_id is null;

update public.hv_users u set employee_id = e.id
from public.employees e where e.user_id = u.auth_user_id and u.employee_id is null;

update public.profiles p set employee_id = e.id
from public.employees e where e.user_id = p.id and p.employee_id is null;

-- ---------------------------------------------------------------------
-- 3. Username -> email for the maintenance login screen (callable before
--    login; returns only the email, nothing else)
-- ---------------------------------------------------------------------
create or replace function public.hv_login_email(p_username text)
returns text language sql stable security definer set search_path = public as $fn$
  select email from public.hv_users
   where lower(username) = lower(p_username) and is_active and auth_user_id is not null
   limit 1
$fn$;
grant execute on function public.hv_login_email(text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. One employee list: terminating someone in HR deactivates them in the
--    maintenance system and blocks their unified login
-- ---------------------------------------------------------------------
create or replace function public.sync_employee_status()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.status = 'terminated' and (old.status is distinct from new.status) then
    update public.hv_users set is_active = false where employee_id = new.id;
    update public.app_users set is_active = false where id = new.user_id;
  elsif new.status = 'active' and old.status = 'terminated' then
    update public.hv_users set is_active = true where employee_id = new.id;
    update public.app_users set is_active = true where id = new.user_id;
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_sync_employee_status on public.employees;
create trigger trg_sync_employee_status after update of status on public.employees
  for each row execute function public.sync_employee_status();
