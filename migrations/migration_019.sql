-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_019.sql
-- KPIs for everyone, not just sales:
--   * kpi_metrics.category  -- sales | property | maintenance | attendance | general
--   * CRM bookings are rentals, not sales deals: new "booking" metric in
--     the property category; the booking trigger and existing CRM entries
--     move to it, so the sales board only ever shows sales work
--   * "on_time_day" metric + kpi_attendance(): on-time days are computed
--     from the fingerprint device / GPS check-ins for every non-exempt
--     employee, so the company-wide board needs no manual entry
--   * "kudos" metric (general) so a manager can recognise anyone
-- ADDITIVE ONLY. Run once, after 018.
-- =====================================================================

alter table public.kpi_metrics add column if not exists category text not null default 'sales';
alter table public.kpi_metrics drop constraint if exists kpi_metrics_category_check;
alter table public.kpi_metrics add constraint kpi_metrics_category_check
  check (category in ('sales','property','maintenance','attendance','general'));

update public.kpi_metrics set category = 'maintenance' where code = 'maintenance_task' and category <> 'maintenance';

insert into public.kpi_metrics (code, name_en, name_ar, points_per_unit, value_points_per_million, has_value, sort, category) values
  ('booking',     'Booking confirmed',            'حجز مؤكد',                 5, 5, true,  6, 'property'),
  ('on_time_day', 'On-time day',                  'يوم حضور في الموعد',        1, 0, false, 7, 'attendance'),
  ('kudos',       'Manager recognition',          'تقدير من المدير',           5, 0, false, 8, 'general')
on conflict (code) do nothing;

-- CRM entries already credited as "Deal closed" become bookings
update public.kpi_entries e set metric_id = m.id
  from public.kpi_metrics m
 where m.code = 'booking' and e.source = 'crm'
   and e.metric_id = (select id from public.kpi_metrics where code = 'closing');

-- the booking trigger now credits the booking metric
create or replace function public.kpi_from_booking()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  emp uuid;
  metric uuid;
  prop text;
begin
  select id into metric from public.kpi_metrics where code = 'booking';
  if metric is null then return new; end if;

  if new.status = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    select p.employee_id into emp from public.profiles p where p.id = auth.uid();
    if emp is null then return new; end if;
    select coalesce(name, '') into prop from public.properties where id = new.property_id;
    insert into public.kpi_entries (employee_id, metric_id, entry_date, quantity, value_egp, reference, status, source, external_id, approved_at, notes)
    values (emp, metric, coalesce(new.created_at::date, current_date), 1,
            case when coalesce(new.currency, 'EGP') = 'EGP' then new.amount else null end,
            trim(coalesce(new.guest_name, '') || ' · ' || coalesce(prop, '')), 'approved', 'crm',
            'booking:' || new.id, now(), 'CRM booking ' || new.start_date || ' → ' || new.end_date)
    on conflict (external_id) do update set status = 'approved', value_egp = excluded.value_egp, metric_id = excluded.metric_id;
  elsif new.status = 'cancelled' and old.status is distinct from new.status then
    update public.kpi_entries set status = 'rejected', notes = coalesce(notes, '') || ' | booking cancelled'
     where external_id = 'booking:' || new.id;
  end if;
  return new;
end;
$fn$;

-- ---------------------------------------------------------------------
-- Attendance KPI, computed on demand for a date range. Same rules as the
-- attendance review screen: first "in" punch (or first punch) of the
-- local day vs the employee's shift start + grace; weekends (employee
-- override or company default) and holidays are skipped; CEOs and other
-- attendance-exempt staff are not scored.
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
           (coalesce(d.first_in, d.first_any))::time
             <= (coalesce(s.start_time, ds.start_time) + make_interval(mins => coalesce(s.grace_minutes, ds.grace_minutes))) as on_time
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
