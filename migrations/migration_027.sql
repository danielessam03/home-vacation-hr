-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_027.sql
-- Shift by weekday: an employee may start at 9:00 some days and 10:30 or
-- 11:00 on others. employees.day_shifts maps weekday (0=Sunday .. 6) to
-- a shift id; days not listed use the employee's default shift.
-- Attendance review, payroll and the attendance KPI all read it.
-- ADDITIVE ONLY. Run once, after 026.
-- =====================================================================

alter table public.employees add column if not exists day_shifts jsonb;   -- {"1": "<shift id>", "3": "<shift id>"}

-- the two extra start times Daniel described, 8-hour days (edit in Settings -> Shifts)
insert into public.shifts (name_en, name_ar, start_time, end_time)
select '10:30 – 18:30', 'وردية 10:30 – 18:30', '10:30', '18:30'
 where not exists (select 1 from public.shifts where start_time = '10:30');
insert into public.shifts (name_en, name_ar, start_time, end_time)
select '11:00 – 19:00', 'وردية 11:00 – 19:00', '11:00', '19:00'
 where not exists (select 1 from public.shifts where start_time = '11:00');

-- attendance KPI: the shift of that weekday
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
      left join public.shifts s
        on s.id = coalesce(
             case when (e.day_shifts->>(extract(dow from d.d)::int)::text) ~ '^[0-9a-f-]{36}$'
                  then (e.day_shifts->>(extract(dow from d.d)::int)::text)::uuid end,
             e.shift_id)
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
