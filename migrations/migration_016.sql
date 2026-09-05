-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_016.sql
-- Attendance exemption: CEOs (and anyone HR flags) have no attendance --
-- no check-in, no lateness/overtime, no live-session prompts. Leave,
-- payroll, KPIs and everything else are unaffected.
-- ADDITIVE ONLY. Run once, after 015.
-- =====================================================================

alter table public.employees add column if not exists attendance_exempt boolean not null default false;

-- anyone whose login carries the CEO role is exempt
update public.employees e set attendance_exempt = true
  from public.app_users u where u.id = e.user_id and u.role = 'ceo' and not e.attendance_exempt;

-- keep it in sync: linking a CEO login to an employee, or promoting a
-- login to CEO, flags the employee automatically
create or replace function public.sync_attendance_exempt()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if tg_table_name = 'employees' then
    if new.user_id is not null and exists (select 1 from public.app_users where id = new.user_id and role = 'ceo') then
      new.attendance_exempt := true;
    end if;
    return new;
  else
    if new.role = 'ceo' then
      update public.employees set attendance_exempt = true where user_id = new.id and not attendance_exempt;
    end if;
    return new;
  end if;
end;
$fn$;

drop trigger if exists trg_exempt_on_employee on public.employees;
create trigger trg_exempt_on_employee before insert or update of user_id on public.employees
  for each row execute function public.sync_attendance_exempt();

drop trigger if exists trg_exempt_on_role on public.app_users;
create trigger trg_exempt_on_role after update of role on public.app_users
  for each row execute function public.sync_attendance_exempt();
