-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_039.sql
-- One person = one employee card + one login, kept in sync:
--   * approving / creating a login with no employee card creates the
--     card (name, code, hire date today) and links it
--   * names edited on either side flow to the other
--   * Mayada Mahrous (login only) gets her card now
-- ADDITIVE ONLY. Run once, after 038.
-- =====================================================================

create or replace function public.employee_from_user()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare v_code text; n int; nm_en text; nm_ar text; branch uuid;
begin
  if new.approval_status <> 'approved' or not new.is_active then return new; end if;
  if exists (select 1 from public.employees where user_id = new.id) then return new; end if;
  -- adopt an unlinked card with the same name, else create one
  nm_en := coalesce(nullif(new.full_name_en, ''), nullif(new.username, ''), split_part(new.email, '@', 1));
  nm_ar := coalesce(nullif(new.full_name_ar, ''), nm_en);
  update public.employees set user_id = new.id
   where user_id is null and status = 'active'
     and (lower(full_name_en) = lower(nm_en) or (nm_ar <> nm_en and full_name_ar = nm_ar));
  if found then return new; end if;
  n := 1;
  loop
    v_code := 'HV-U' || lpad(n::text, 3, '0');
    exit when not exists (select 1 from public.employees where employee_code = v_code);
    n := n + 1;
  end loop;
  select id into branch from public.branches where id = new.branch_id;
  insert into public.employees (employee_code, full_name_en, full_name_ar, user_id, branch_id, hire_date, contract_type, status,
                                job_title_en, job_title_ar, attendance_exempt)
  values (v_code, nm_en, nm_ar, new.id, coalesce(branch, (select id from public.branches b where b.code = 'HRG-HO')), current_date, 'indefinite', 'active',
          case new.role when 'ceo' then 'Chief Executive Officer' when 'hr' then 'HR' when 'accountant' then 'Accountant' when 'manager' then 'Manager' else null end,
          case new.role when 'ceo' then 'الرئيس التنفيذي' when 'hr' then 'الموارد البشرية' when 'accountant' then 'محاسب' when 'manager' then 'مدير' else null end,
          new.role = 'ceo');
  return new;
end;
$fn$;
drop trigger if exists trg_employee_from_user on public.app_users;
create trigger trg_employee_from_user after insert or update of approval_status, is_active on public.app_users
  for each row execute function public.employee_from_user();

-- names: employee card -> login, login -> employee card (no loops: only when different)
create or replace function public.sync_names_emp_to_user()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.user_id is not null then
    update public.app_users set full_name_en = new.full_name_en, full_name_ar = new.full_name_ar
     where id = new.user_id and (full_name_en is distinct from new.full_name_en or full_name_ar is distinct from new.full_name_ar);
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_sync_names_emp on public.employees;
create trigger trg_sync_names_emp after insert or update of full_name_en, full_name_ar, user_id on public.employees
  for each row execute function public.sync_names_emp_to_user();

create or replace function public.sync_names_user_to_emp()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  update public.employees set full_name_en = coalesce(nullif(new.full_name_en, ''), full_name_en), full_name_ar = coalesce(nullif(new.full_name_ar, ''), full_name_ar)
   where user_id = new.id and (full_name_en is distinct from coalesce(nullif(new.full_name_en, ''), full_name_en) or full_name_ar is distinct from coalesce(nullif(new.full_name_ar, ''), full_name_ar));
  return new;
end;
$fn$;
drop trigger if exists trg_sync_names_user on public.app_users;
create trigger trg_sync_names_user after update of full_name_en, full_name_ar on public.app_users
  for each row execute function public.sync_names_user_to_emp();

-- backfill: every approved login without a card
do $b$
declare r record;
begin
  for r in select a.* from public.app_users a where a.approval_status = 'approved' and a.is_active and not exists (select 1 from public.employees e where e.user_id = a.id) loop
    update public.app_users set is_active = is_active where id = r.id;   -- fires the trigger
  end loop;
end $b$;
