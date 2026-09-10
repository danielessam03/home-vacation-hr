-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_035.sql
-- 1. Year calendar: everyone can see approved leaves of everyone.
-- 2. Automatic make-up days: a punch on the employee's own rest day
--    (on a company working day) creates the claim by itself, with
--    first in / last out / hours and a credit of full day, half day or
--    none by thresholds (Settings -> Work week). A make-up day no longer
--    has to follow a leave; approval credits the year of the work day.
-- ADDITIVE ONLY. Run once, after 034.
-- =====================================================================

drop policy if exists leave_req_select on public.leave_requests;
create policy leave_req_select on public.leave_requests for select to authenticated
  using (
    status = 'approved'
    or public.has_role('ceo','hr','accountant')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );

alter table public.leave_makeups add column if not exists first_in    timestamptz;
alter table public.leave_makeups add column if not exists last_out    timestamptz;
alter table public.leave_makeups add column if not exists hours       numeric(5,2);
alter table public.leave_makeups add column if not exists credit_days numeric(3,1) not null default 1;
alter table public.leave_makeups add column if not exists auto        boolean not null default false;

update public.app_settings set value = value || '{"makeup_full_hours": 7, "makeup_half_hours": 4}'::jsonb
 where key = 'work_week' and not (value ? 'makeup_full_hours');

-- ---------------------------------------------------------------------
-- Validation: the leave link is now optional
-- ---------------------------------------------------------------------
create or replace function public.leave_makeup_check(p_employee uuid, p_work_date date, p_leave uuid)
returns text language plpgsql stable security definer set search_path = public as $fn$
declare
  e record; lr record; ww jsonb; weeks int; dow int; punches int; approved_for_leave int;
begin
  select * into e from public.employees where id = p_employee;
  if e is null then return 'no_employee'; end if;
  if e.attendance_exempt then return 'exempt'; end if;
  ww := coalesce((select value from public.app_settings where key = 'work_week'), '{}'::jsonb);
  weeks := coalesce((ww->>'makeup_window_weeks')::int, 4);
  dow := extract(dow from p_work_date)::int;
  if e.weekend_days is null or not (e.weekend_days @> to_jsonb(dow)) then return 'not_rest_day'; end if;
  if coalesce(ww->'weekend_days', '[5,6]'::jsonb) @> to_jsonb(dow) then return 'company_off'; end if;
  if exists (select 1 from public.holidays h where h.holiday_date = p_work_date and (h.branch_id is null or h.branch_id = e.branch_id)) then return 'holiday'; end if;
  if p_work_date > current_date then return 'future'; end if;
  if p_leave is not null then
    select * into lr from public.leave_requests where id = p_leave and employee_id = p_employee;
    if lr is null then return 'no_leave'; end if;
    if lr.status <> 'approved' then return 'leave_not_approved'; end if;
    if p_work_date <= lr.end_date then return 'before_leave_end'; end if;
    if p_work_date > lr.end_date + (weeks * 7) then return 'window_passed'; end if;
    select count(*) into approved_for_leave from public.leave_makeups where leave_request_id = p_leave and status = 'approved' and employee_id = p_employee;
    if approved_for_leave >= ceil(lr.days) then return 'leave_fully_compensated'; end if;
  end if;
  select count(*) into punches from public.attendance_punches p
   where p.employee_id = p_employee and (p.punch_time at time zone 'Africa/Cairo')::date = p_work_date;
  if punches = 0 then return 'no_attendance'; end if;
  return null;
end;
$fn$;

-- ---------------------------------------------------------------------
-- Build / refresh the automatic claim for one employee-day from punches
-- ---------------------------------------------------------------------
create or replace function public.makeup_refresh(p_employee uuid, p_work_date date)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  e record; ww jsonb; dow int; f timestamptz; l timestamptz; n int; h numeric; credit numeric; full_h numeric; half_h numeric;
begin
  select * into e from public.employees where id = p_employee;
  if e is null or e.attendance_exempt or e.status <> 'active' or e.weekend_days is null then return; end if;
  ww := coalesce((select value from public.app_settings where key = 'work_week'), '{}'::jsonb);
  dow := extract(dow from p_work_date)::int;
  if not (e.weekend_days @> to_jsonb(dow)) then return; end if;                       -- not the employee's rest day
  if coalesce(ww->'weekend_days', '[5,6]'::jsonb) @> to_jsonb(dow) then return; end if; -- company closed anyway
  if exists (select 1 from public.holidays x where x.holiday_date = p_work_date and (x.branch_id is null or x.branch_id = e.branch_id)) then return; end if;
  select min(punch_time), max(punch_time), count(*) into f, l, n from public.attendance_punches
   where employee_id = p_employee and (punch_time at time zone 'Africa/Cairo')::date = p_work_date;
  if n = 0 then
    delete from public.leave_makeups where employee_id = p_employee and work_date = p_work_date and auto and status = 'pending';
    return;
  end if;
  h := case when n >= 2 then round(extract(epoch from (l - f)) / 3600.0, 2) else 0 end;
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

-- the claim insert trigger must accept automatic rows (they carry no leave)
create or replace function public.leave_makeup_before_insert()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare why text;
begin
  if not new.auto then
    why := public.leave_makeup_check(new.employee_id, new.work_date, new.leave_request_id);
    if why is not null then raise exception 'makeup:%', why; end if;
  end if;
  new.status := 'pending';
  new.created_by := coalesce(new.created_by, auth.uid());
  return new;
end;
$fn$;

create or replace function public.makeup_from_punch()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare r record;
begin
  r := case when tg_op = 'DELETE' then old else new end;
  if r.employee_id is not null then
    perform public.makeup_refresh(r.employee_id, (r.punch_time at time zone 'Africa/Cairo')::date);
  end if;
  if tg_op = 'UPDATE' and (old.employee_id is distinct from new.employee_id or old.punch_time is distinct from new.punch_time) and old.employee_id is not null then
    perform public.makeup_refresh(old.employee_id, (old.punch_time at time zone 'Africa/Cairo')::date);
  end if;
  return null;
end;
$fn$;
drop trigger if exists trg_makeup_from_punch on public.attendance_punches;
create trigger trg_makeup_from_punch after insert or update or delete on public.attendance_punches
  for each row execute function public.makeup_from_punch();

-- ---------------------------------------------------------------------
-- Approval: credit = credit_days (approver may override), year of the work day
-- ---------------------------------------------------------------------
create or replace function public.decide_leave_makeup(p_id uuid, p_approve boolean, p_note text default null, p_credit numeric default null)
returns public.leave_makeups language plpgsql security definer set search_path = public as $fn$
declare
  m public.leave_makeups; lr record; why text; adj uuid; annual uuid; credit numeric; yr int;
begin
  select * into m from public.leave_makeups where id = p_id;
  if m is null then raise exception 'not found'; end if;
  if not (public.has_role('ceo','hr') or exists (select 1 from public.employees e where e.id = m.employee_id and e.manager_id = public.my_employee_id())) then
    raise exception 'forbidden';
  end if;
  if m.status <> 'pending' then raise exception 'already decided'; end if;
  if p_approve then
    if not m.auto then
      why := public.leave_makeup_check(m.employee_id, m.work_date, m.leave_request_id);
      if why is not null then raise exception 'makeup:%', why; end if;
    end if;
    credit := coalesce(p_credit, m.credit_days, 1);
    yr := extract(year from m.work_date)::int;
    if m.leave_request_id is not null then
      select * into lr from public.leave_requests where id = m.leave_request_id;
      if lr is not null then yr := extract(year from lr.start_date)::int; end if;
    end if;
    if credit > 0 then
      select id into annual from public.leave_types where code = 'annual';
      insert into public.leave_adjustments (employee_id, leave_type_id, year, days, reason, created_by)
      values (m.employee_id, annual, yr, credit,
              'Make-up day: worked ' || m.work_date || coalesce(' (' || to_char(m.first_in at time zone 'Africa/Cairo', 'HH24:MI') || '-' || to_char(m.last_out at time zone 'Africa/Cairo', 'HH24:MI') || ', ' || m.hours || ' h)', ''), auth.uid())
      returning id into adj;
    end if;
    update public.leave_makeups set status = 'approved', credit_days = credit, decided_by = auth.uid(), decided_at = now(), decision_note = p_note, adjustment_id = adj
     where id = p_id returning * into m;
  else
    update public.leave_makeups set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
     where id = p_id returning * into m;
  end if;
  return m;
end;
$fn$;
grant execute on function public.decide_leave_makeup(uuid, boolean, text, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- Backfill this year: every punch day on an employee's own rest day
-- ---------------------------------------------------------------------
do $b$
declare r record;
begin
  for r in select distinct p.employee_id, (p.punch_time at time zone 'Africa/Cairo')::date as d
             from public.attendance_punches p join public.employees e on e.id = p.employee_id
            where p.punch_time >= date_trunc('year', current_date) and e.weekend_days is not null
  loop
    perform public.makeup_refresh(r.employee_id, r.d);
  end loop;
end $b$;
