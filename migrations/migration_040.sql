-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_040.sql
-- The fingerprint device has four buttons, not two:
--   0 = check in, 1 = check out, 2 = break out, 3 = break in
-- (also 4/5 = overtime in/out). Break punches were stored as 'unknown'
-- and mistaken for the end of the day. New directions, plus the SQL
-- helpers now ignore break punches when finding first in / last out and
-- count device breaks in the make-up hours.
-- ADDITIVE ONLY. Run once, after 039.
-- =====================================================================

alter table public.attendance_punches drop constraint if exists attendance_punches_direction_check;
alter table public.attendance_punches add constraint attendance_punches_direction_check
  check (direction in ('in','out','break_out','break_in','ot_in','ot_out','unknown'));

-- attendance KPI: first "in" ignores break presses
create or replace function public.kpi_attendance(p_from date, p_to date)
returns table (employee_id uuid, on_time_days int, late_days int, worked_days int)
language sql stable security definer set search_path = public as $fn$
  with ww as (
    select coalesce((select value->'weekend_days' from public.app_settings where key = 'work_week'), '[5,6]'::jsonb) as weekend
  ),
  defshift as (
    select start_time, grace_minutes, day_hours from public.shifts where is_active order by created_at limit 1
  ),
  days as (
    select p.employee_id,
           (p.punch_time at time zone 'Africa/Cairo')::date as d,
           min(p.punch_time at time zone 'Africa/Cairo') filter (where p.direction = 'in') as first_in,
           min(p.punch_time at time zone 'Africa/Cairo') filter (where p.direction not in ('break_out','break_in','ot_in','ot_out')) as first_any
      from public.attendance_punches p
     where p.employee_id is not null
       and (p.punch_time at time zone 'Africa/Cairo')::date between p_from and p_to
     group by 1, 2
  ),
  scored as (
    select d.employee_id, d.d,
           ((coalesce(d.first_in, d.first_any))::time
             <= (coalesce(
                   (s.day_hours->(extract(dow from d.d)::int)::text->>'start')::time,
                   s.start_time,
                   (ds.day_hours->(extract(dow from d.d)::int)::text->>'start')::time,
                   ds.start_time)
                 + make_interval(mins => coalesce(s.grace_minutes, ds.grace_minutes))))
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
       and coalesce(d.first_in, d.first_any) is not null
  )
  select employee_id,
         count(*) filter (where on_time)::int     as on_time_days,
         count(*) filter (where not on_time)::int as late_days,
         count(*)::int                            as worked_days
    from scored
   group by employee_id
$fn$;
grant execute on function public.kpi_attendance(date, date) to authenticated;

-- automatic make-up day: first in / last out from real in/out presses, hours net of device breaks
create or replace function public.makeup_refresh(p_employee uuid, p_work_date date)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  e record; ww jsonb; dow int; f timestamptz; l timestamptz; n int; h numeric; credit numeric; full_h numeric; half_h numeric; brk numeric;
begin
  select * into e from public.employees where id = p_employee;
  if e is null or e.attendance_exempt or e.status <> 'active' or e.weekend_days is null then return; end if;
  ww := coalesce((select value from public.app_settings where key = 'work_week'), '{}'::jsonb);
  dow := extract(dow from p_work_date)::int;
  if not (e.weekend_days @> to_jsonb(dow)) then return; end if;
  if coalesce(ww->'weekend_days', '[5,6]'::jsonb) @> to_jsonb(dow) then return; end if;
  if exists (select 1 from public.holidays x where x.holiday_date = p_work_date and (x.branch_id is null or x.branch_id = e.branch_id)) then return; end if;
  select min(punch_time), max(punch_time), count(*) into f, l, n from public.attendance_punches
   where employee_id = p_employee and (punch_time at time zone 'Africa/Cairo')::date = p_work_date
     and direction not in ('break_out','break_in','ot_in','ot_out');
  if n = 0 then
    delete from public.leave_makeups where employee_id = p_employee and work_date = p_work_date and auto and status = 'pending';
    return;
  end if;
  -- device breaks that day (break_out -> next break_in)
  select coalesce(sum(extract(epoch from (bi.punch_time - bo.punch_time)) / 3600.0), 0) into brk
    from public.attendance_punches bo
    join lateral (select punch_time from public.attendance_punches x where x.employee_id = bo.employee_id and x.direction = 'break_in' and x.punch_time > bo.punch_time order by x.punch_time limit 1) bi on true
   where bo.employee_id = p_employee and bo.direction = 'break_out' and (bo.punch_time at time zone 'Africa/Cairo')::date = p_work_date;
  h := case when n >= 2 then greatest(0, round(extract(epoch from (l - f)) / 3600.0 - brk, 2)) else 0 end;
  full_h := coalesce((ww->>'makeup_full_hours')::numeric, 7);
  half_h := coalesce((ww->>'makeup_half_hours')::numeric, 4);
  credit := case when h >= full_h then 1 when h >= half_h then 0.5 else 0 end;
  insert into public.leave_makeups (employee_id, work_date, status, first_in, last_out, hours, credit_days, auto, note)
  values (p_employee, p_work_date, 'pending', f, case when n >= 2 then l end, h, credit, true, 'Detected from check-in')
  on conflict (employee_id, work_date) do update
    set first_in = excluded.first_in, last_out = excluded.last_out, hours = excluded.hours,
        credit_days = case when public.leave_makeups.status = 'pending' and public.leave_makeups.auto then excluded.credit_days else public.leave_makeups.credit_days end;
end;
$fn$;
