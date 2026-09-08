-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_022.sql
-- 1. Leave make-up days: an employee whose personal rest day falls on a
--    company working day (e.g. Saturday off while the office works
--    Saturdays) may, in the weeks after a leave, work that rest day and
--    claim one leave day back. Claims are validated server-side against
--    the fingerprint/GPS punches and, on approval, credit the annual
--    balance through leave_adjustments.
-- 2. Salaries are for accounting and the CEO only: HR loses read access
--    to payroll runs and items (HR keeps everything else).
-- ADDITIVE ONLY. Run once, after 021.
-- =====================================================================

create table if not exists public.leave_makeups (
  id               uuid primary key default gen_random_uuid(),
  employee_id      uuid not null references public.employees(id),
  leave_request_id uuid references public.leave_requests(id),
  work_date        date not null,
  status           text not null default 'pending' check (status in ('pending','approved','rejected')),
  note             text,
  decided_by       uuid references public.app_users(id),
  decided_at       timestamptz,
  decision_note    text,
  adjustment_id    uuid references public.leave_adjustments(id),
  created_by       uuid references public.app_users(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (employee_id, work_date)
);
create index if not exists idx_leave_makeups_emp on public.leave_makeups(employee_id, work_date);
drop trigger if exists trg_leave_makeups_touch on public.leave_makeups;
create trigger trg_leave_makeups_touch before update on public.leave_makeups
  for each row execute function public.touch_updated_at();

alter table public.leave_makeups enable row level security;
drop policy if exists leave_makeups_select on public.leave_makeups;
create policy leave_makeups_select on public.leave_makeups for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );
drop policy if exists leave_makeups_insert on public.leave_makeups;
create policy leave_makeups_insert on public.leave_makeups for insert to authenticated
  with check ( employee_id = public.my_employee_id() or public.has_role('ceo','hr') );
drop policy if exists leave_makeups_delete on public.leave_makeups;
create policy leave_makeups_delete on public.leave_makeups for delete to authenticated
  using ( (employee_id = public.my_employee_id() and status = 'pending') or public.has_role('ceo','hr') );
-- updates only through decide_leave_makeup() below (security definer)

-- how many weeks after a leave a make-up day may be worked (Settings -> work week)
update public.app_settings set value = value || '{"makeup_window_weeks": 4}'::jsonb
 where key = 'work_week' and not (value ? 'makeup_window_weeks');

-- ---------------------------------------------------------------------
-- Validation shared by claim and approval. Returns null when the day is
-- a valid make-up day for that employee, else the reason code.
-- ---------------------------------------------------------------------
create or replace function public.leave_makeup_check(p_employee uuid, p_work_date date, p_leave uuid)
returns text language plpgsql stable security definer set search_path = public as $fn$
declare
  e record; lr record;
  ww jsonb; weeks int; dow int;
  punches int; approved_for_leave int;
begin
  select * into e from public.employees where id = p_employee;
  if e is null then return 'no_employee'; end if;
  if e.attendance_exempt then return 'exempt'; end if;
  ww := coalesce((select value from public.app_settings where key = 'work_week'), '{}'::jsonb);
  weeks := coalesce((ww->>'makeup_window_weeks')::int, 4);
  dow := extract(dow from p_work_date)::int;
  -- must be the employee's own rest day ...
  if e.weekend_days is null or not (e.weekend_days @> to_jsonb(dow)) then return 'not_rest_day'; end if;
  -- ... on a day the company works
  if coalesce(ww->'weekend_days', '[5,6]'::jsonb) @> to_jsonb(dow) then return 'company_off'; end if;
  if exists (select 1 from public.holidays h where h.holiday_date = p_work_date and (h.branch_id is null or h.branch_id = e.branch_id)) then return 'holiday'; end if;
  if p_work_date > current_date then return 'future'; end if;
  -- the leave it compensates: approved, ended before the work day, within the window
  select * into lr from public.leave_requests where id = p_leave and employee_id = p_employee;
  if lr is null then return 'no_leave'; end if;
  if lr.status <> 'approved' then return 'leave_not_approved'; end if;
  if p_work_date <= lr.end_date then return 'before_leave_end'; end if;
  if p_work_date > lr.end_date + (weeks * 7) then return 'window_passed'; end if;
  select count(*) into approved_for_leave from public.leave_makeups
   where leave_request_id = p_leave and status = 'approved' and employee_id = p_employee;
  if approved_for_leave >= ceil(lr.days) then return 'leave_fully_compensated'; end if;
  -- the person actually came in that day (device, GPS or manual punch)
  select count(*) into punches from public.attendance_punches p
   where p.employee_id = p_employee and (p.punch_time at time zone 'Africa/Cairo')::date = p_work_date;
  if punches = 0 then return 'no_attendance'; end if;
  return null;
end;
$fn$;
grant execute on function public.leave_makeup_check(uuid, date, uuid) to authenticated;

-- claims are validated on insert
create or replace function public.leave_makeup_before_insert()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare why text;
begin
  why := public.leave_makeup_check(new.employee_id, new.work_date, new.leave_request_id);
  if why is not null then raise exception 'makeup:%', why; end if;
  new.status := 'pending';
  new.created_by := coalesce(new.created_by, auth.uid());
  return new;
end;
$fn$;
drop trigger if exists trg_leave_makeup_insert on public.leave_makeups;
create trigger trg_leave_makeup_insert before insert on public.leave_makeups
  for each row execute function public.leave_makeup_before_insert();

-- ---------------------------------------------------------------------
-- Approve / reject. Caller must be ceo/hr or the employee's manager.
-- Approval re-validates and credits +1 annual day for the leave's year.
-- ---------------------------------------------------------------------
create or replace function public.decide_leave_makeup(p_id uuid, p_approve boolean, p_note text default null)
returns public.leave_makeups language plpgsql security definer set search_path = public as $fn$
declare
  m public.leave_makeups; lr record; why text; adj uuid; annual uuid;
begin
  select * into m from public.leave_makeups where id = p_id;
  if m is null then raise exception 'not found'; end if;
  if not (public.has_role('ceo','hr') or exists (select 1 from public.employees e where e.id = m.employee_id and e.manager_id = public.my_employee_id())) then
    raise exception 'forbidden';
  end if;
  if m.status <> 'pending' then raise exception 'already decided'; end if;
  if p_approve then
    why := public.leave_makeup_check(m.employee_id, m.work_date, m.leave_request_id);
    if why is not null then raise exception 'makeup:%', why; end if;
    select * into lr from public.leave_requests where id = m.leave_request_id;
    select id into annual from public.leave_types where code = 'annual';
    insert into public.leave_adjustments (employee_id, leave_type_id, year, days, reason, created_by)
    values (m.employee_id, annual, extract(year from lr.start_date)::int, 1,
            'Make-up day: worked ' || m.work_date || ' after leave ' || lr.start_date || ' → ' || lr.end_date, auth.uid())
    returning id into adj;
    update public.leave_makeups set status = 'approved', decided_by = auth.uid(), decided_at = now(), decision_note = p_note, adjustment_id = adj
     where id = p_id returning * into m;
  else
    update public.leave_makeups set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
     where id = p_id returning * into m;
  end if;
  return m;
end;
$fn$;
grant execute on function public.decide_leave_makeup(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------------------
-- 2. Payroll figures: accounting and CEO only (employees still see their
--    own payslips from approved runs)
-- ---------------------------------------------------------------------
drop policy if exists payroll_runs_select on public.payroll_runs;
create policy payroll_runs_select on public.payroll_runs for select to authenticated
  using (
    public.has_role('ceo','accountant')
    or (status = 'approved' and exists (
      select 1 from public.payroll_items i
       where i.run_id = payroll_runs.id and i.employee_id = public.my_employee_id()))
  );
drop policy if exists payroll_items_select on public.payroll_items;
create policy payroll_items_select on public.payroll_items for select to authenticated
  using (
    public.has_role('ceo','accountant')
    or (employee_id = public.my_employee_id() and exists (
      select 1 from public.payroll_runs r
       where r.id = payroll_items.run_id and r.status = 'approved'))
  );
