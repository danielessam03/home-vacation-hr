-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_023.sql
-- Attendance exceptions: an employee writes a note BEFORE arriving late,
-- taking a longer break or leaving early. The manager / HR accept or
-- reject it. An accepted note excuses that day: no lateness deduction in
-- payroll, no late mark in the review or the attendance KPI.
-- ADDITIVE ONLY. Run once, after 022.
-- =====================================================================

create table if not exists public.attendance_exceptions (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references public.employees(id),
  exc_date      date not null,
  kind          text not null check (kind in ('late','break','early_leave')),
  minutes       int,                       -- expected delay / extra break length
  reason        text not null,
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by    uuid references public.app_users(id),
  decided_at    timestamptz,
  decision_note text,
  created_by    uuid references public.app_users(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_att_exc_emp_date on public.attendance_exceptions(employee_id, exc_date);
create index if not exists idx_att_exc_status on public.attendance_exceptions(status);
drop trigger if exists trg_att_exc_touch on public.attendance_exceptions;
create trigger trg_att_exc_touch before update on public.attendance_exceptions
  for each row execute function public.touch_updated_at();

alter table public.attendance_exceptions enable row level security;
drop policy if exists att_exc_select on public.attendance_exceptions;
create policy att_exc_select on public.attendance_exceptions for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );
-- staff must write the note in advance (today or later); HR may record it any time
drop policy if exists att_exc_insert on public.attendance_exceptions;
create policy att_exc_insert on public.attendance_exceptions for insert to authenticated
  with check (
    public.has_role('ceo','hr')
    or (employee_id = public.my_employee_id() and exc_date >= current_date and status = 'pending')
  );
drop policy if exists att_exc_update on public.attendance_exceptions;
create policy att_exc_update on public.attendance_exceptions for update to authenticated
  using (
    public.has_role('ceo','hr')
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  )
  with check (
    public.has_role('ceo','hr')
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );
drop policy if exists att_exc_delete on public.attendance_exceptions;
create policy att_exc_delete on public.attendance_exceptions for delete to authenticated
  using ( (employee_id = public.my_employee_id() and status = 'pending') or public.has_role('ceo','hr') );

-- ---------------------------------------------------------------------
-- Attendance KPI: an approved late/early-leave note counts as on time
-- ---------------------------------------------------------------------
create or replace function public.kpi_attendance(p_from date, p_to date)
returns table (employee_id uuid, on_time_days int, late_days int, worked_days int)
language sql stable security definer set search_path = public as $fn$
  with ww as (
    select coalesce((select value->'weekend_days' from public.app_settings where key = 'work_week'), '[5,6]'::jsonb) as weekend
  ),
  defshift as (
    select start_time, grace_minutes from public.shifts where is_active order by created_at limit 1
  ),
  days as (
    select p.employee_id,
           (p.punch_time at time zone 'Africa/Cairo')::date as d,
           min(p.punch_time at time zone 'Africa/Cairo') filter (where p.direction = 'in') as first_in,
           min(p.punch_time at time zone 'Africa/Cairo') as first_any
      from public.attendance_punches p
     where p.employee_id is not null
       and (p.punch_time at time zone 'Africa/Cairo')::date between p_from and p_to
     group by 1, 2
  ),
  scored as (
    select d.employee_id, d.d,
           ((coalesce(d.first_in, d.first_any))::time
             <= (coalesce(s.start_time, ds.start_time) + make_interval(mins => coalesce(s.grace_minutes, ds.grace_minutes))))
           or exists (select 1 from public.attendance_exceptions x
                       where x.employee_id = d.employee_id and x.exc_date = d.d and x.status = 'approved' and x.kind in ('late','early_leave')) as on_time
      from days d
      join public.employees e on e.id = d.employee_id
      left join public.shifts s on s.id = e.shift_id
      cross join defshift ds
      cross join ww
     where e.status = 'active' and not e.attendance_exempt
       and not (coalesce(e.weekend_days, ww.weekend) @> to_jsonb(extract(dow from d.d)::int))
       and not exists (select 1 from public.holidays h where h.holiday_date = d.d and (h.branch_id is null or h.branch_id = e.branch_id))
  )
  select employee_id,
         count(*) filter (where on_time)::int     as on_time_days,
         count(*) filter (where not on_time)::int as late_days,
         count(*)::int                            as worked_days
    from scored
   group by employee_id
$fn$;
grant execute on function public.kpi_attendance(date, date) to authenticated;
