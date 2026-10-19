-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_052.sql
-- HV Management, the 6th Home Vacation system: the CEO dashboard
-- (executive information system). It READS the other systems and never
-- writes to them.
--
--   * app_users.access_mgmt  = the "HV Management" tick in HR -> Users.
--     Only an active CEO login may hold it, and only a CEO may tick or
--     untick it (trigger mgmt_access_guard). A login that stops being a
--     CEO loses it at once.
--   * public.mgmt_overview(p_from, p_to) and public.mgmt_trend(p_months)
--     are the only calls the app makes. Both refuse anyone who is not an
--     active CEO with the tick (MGMT_ONLY), in the database, whatever
--     the screen shows.
--   * Numbers (Daniel, 2026-10-18): money from HV Finance (posted entries
--     only) + money collected in the other systems that is not in the
--     books yet (fin_money_hub); people from HR (salary bill = approved
--     payroll, else the employee cards, marked as an estimate); work from
--     Maintenance and HV Ops.
--   * 'mgmt' joins hv_my_systems() and hv_alert_counts() (hv_alerts_mgmt).
--   * The three CEO logins get the tick (Daniel's answer: all three CEOs).
-- To add a number later: add it to mgmt_period (period / as-of-a-date)
-- or mgmt_now (right now) in a new migration, then a tile in the app.
-- ADDITIVE ONLY. Safe to re-run. Run after 051.
-- =====================================================================

alter table public.app_users add column if not exists access_mgmt boolean not null default false;

-- ---------------------------------------------------------------- who may open HV Management
create or replace function public.mgmt_allowed(p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $fn$
  select p_uid is not null and exists (
    select 1 from public.app_users a
     where a.id = p_uid and a.is_active and coalesce(a.access_mgmt, false) and a.role = 'ceo')
$fn$;

create or replace function public.mgmt_require()
returns void language plpgsql stable security definer set search_path = public as $fn$
begin
  if not public.mgmt_allowed(auth.uid()) then
    raise exception 'MGMT_ONLY: HV Management is open only to CEOs with the HV Management tick' using errcode = '42501';
  end if;
end;
$fn$;

-- only a CEO login can hold the tick, and only a CEO can change it (the server itself, auth.uid() null, may)
create or replace function public.mgmt_access_guard()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  v_actor uuid := auth.uid();
begin
  -- no longer a CEO -> no HV Management (taking it away is always allowed)
  if tg_op = 'UPDATE' and new.role is distinct from old.role and coalesce(new.role, '') <> 'ceo' then
    new.access_mgmt := false;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.access_mgmt is not distinct from old.access_mgmt then return new; end if;
  if tg_op = 'INSERT' and not coalesce(new.access_mgmt, false) then return new; end if;
  if coalesce(new.access_mgmt, false) and coalesce(new.role, '') <> 'ceo' then
    raise exception 'MGMT_CEO_ONLY: HV Management is for CEO logins only' using errcode = '42501';
  end if;
  if v_actor is not null and not exists (select 1 from public.app_users a where a.id = v_actor and a.is_active and a.role = 'ceo') then
    raise exception 'MGMT_CEO_ONLY: only a CEO can switch HV Management on or off' using errcode = '42501';
  end if;
  return new;
end;
$fn$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_mgmt_access_guard' and tgrelid = 'public.app_users'::regclass) then
    create trigger trg_mgmt_access_guard before insert or update of access_mgmt, role on public.app_users
      for each row execute function public.mgmt_access_guard();
  end if;
end $$;

-- ---------------------------------------------------------------- money position on a date (HV Finance, posted entries)
-- Same arithmetic as the HV Finance home page: cash = lines on the ACTIVE cash & bank accounts
-- (per currency in that currency, and its EGP value); owners' money = account 2210 per owner and
-- currency, counted where we owe the owner (what Finance shows as "We owe owners"); owners owe
-- us = owner balances below zero + 1220; receivable / payable = their account classes.
create or replace function public.mgmt_money_at(p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_base text := coalesce((select c.code from fin_currencies c where c.is_base limit 1), 'EGP');
  v_r record; v_o record;
  v_cash jsonb; v_cash_egp numeric;
begin
  select coalesce(sum(l.debit - l.credit) filter (where a.class = 'receivable'), 0) as receivable,
         coalesce(sum(l.credit - l.debit) filter (where a.class = 'payable'), 0) as payable,
         coalesce(sum(l.debit - l.credit) filter (where l.party_id is not null and a.system_key = 'ar_owners'), 0) as ar_owners
    into v_r
    from fin_journal_lines l
    join fin_journals j on j.id = l.journal_id and j.status = 'posted' and j.journal_date <= p_to
    join fin_accounts a on a.id = l.account_id;

  select coalesce(jsonb_object_agg(x.cur, x.amt), '{}'::jsonb), coalesce(sum(x.egp), 0)
    into v_cash, v_cash_egp
    from (select c.currency as cur,
                 round(sum(case when l.debit > 0 then 1 else -1 end
                           * coalesce(l.amount_fc, case when l.currency = v_base then l.debit + l.credit else 0 end)), 2) as amt,
                 sum(l.debit - l.credit) as egp
            from fin_journal_lines l
            join fin_journals j on j.id = l.journal_id and j.status = 'posted' and j.journal_date <= p_to
            join fin_cash_accounts c on c.id = l.cash_account_id and c.is_active
           group by c.currency) x;

  with g as (
    select l.party_id, l.currency,
           sum(case when l.credit > 0 then 1 else -1 end
               * coalesce(l.amount_fc, case when l.currency = v_base then l.debit + l.credit else 0 end)) as due,
           sum(l.credit - l.debit) as egp
      from fin_journal_lines l
      join fin_journals j on j.id = l.journal_id and j.status = 'posted' and j.journal_date <= p_to
      join fin_accounts a on a.id = l.account_id and a.system_key = 'owner_trust'
     where l.party_id is not null
     group by 1, 2)
  select coalesce(sum(g.egp) filter (where g.due > 0.004), 0) as held_egp,
         coalesce(-sum(g.egp) filter (where g.due < -0.004), 0) as below_egp,
         count(distinct g.party_id) filter (where g.due > 0.004) as owners,
         coalesce((select jsonb_object_agg(h.currency, round(h.s, 2))
                     from (select g2.currency, sum(g2.due) as s from g g2 where g2.due > 0.004 group by 1) h), '{}'::jsonb) as held
    into v_o from g;

  return jsonb_build_object(
    'cash', v_cash, 'cash_egp', round(v_cash_egp, 2),
    'owners_held', v_o.held, 'owners_held_egp', round(v_o.held_egp, 2), 'owners_n', v_o.owners,
    'owners_owe_us_egp', round(v_o.below_egp + v_r.ar_owners, 2),
    'receivable', round(v_r.receivable, 2), 'payable', round(v_r.payable, 2));
end;
$fn$;

-- ---------------------------------------------------------------- the numbers of one period
-- Flows count inside p_from .. p_to (never after today); balances are "on p_to".
create or replace function public.mgmt_period(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_today   date := (now() at time zone 'Africa/Cairo')::date;
  v_to      date := least(p_to, v_today);
  v_att_to  date := case when p_to >= v_today then v_today - 1 else p_to end;   -- attendance counts whole days only
  v_weekend jsonb := coalesce((select s.value -> 'weekend_days' from app_settings s where s.key = 'work_week'), '[5,6]'::jsonb);
  v_fl record; v_hc record; v_exp record; v_att record; v_pay record; v_card record; v_mt record; v_ol record; v_ot record;
  v_hub jsonb; v_leave_days int; v_leave_req int;
begin
  if p_from is null or p_to is null or p_from > p_to then raise exception 'BAD_PERIOD'; end if;

  -- ===== MONEY: income and costs of the period (HV Finance, posted entries)
  select coalesce(sum(l.credit - l.debit) filter (where a.type = 'income'), 0) as income,
         coalesce(sum(l.debit - l.credit) filter (where a.type = 'expense'), 0) as costs,
         count(distinct j.id) as entries
    into v_fl
    from fin_journal_lines l
    join fin_journals j on j.id = l.journal_id and j.status = 'posted' and j.journal_date between p_from and v_to
    join fin_accounts a on a.id = l.account_id;

  -- money the other systems say came in during the period, and how much of it is not in the books yet
  -- (HV Finance's "All systems" list; it needs the HV Finance tick, so it may be missing)
  begin
    with h as (select * from public.fin_money_hub()),
         cin as (select * from h where h.direction = 'in' and h.stage = 'collected' and h.doc_date between p_from and v_to)
    select jsonb_build_object(
             'ok', true,
             'collected_n', (select count(*) from cin),
             'collected', coalesce((select jsonb_object_agg(z.currency, z.s) from (select cin.currency, round(sum(cin.amount), 2) as s from cin group by 1) z), '{}'::jsonb),
             'not_booked_n', (select count(*) from cin where cin.can_bring),
             'not_booked', coalesce((select jsonb_object_agg(z.currency, z.s) from (select cin.currency, round(sum(cin.amount), 2) as s from cin where cin.can_bring group by 1) z), '{}'::jsonb))
      into v_hub;
  exception when others then
    v_hub := jsonb_build_object('ok', false);
  end;

  -- ===== PEOPLE (HR)
  select count(*) filter (where coalesce(e.hire_date, (e.created_at at time zone 'Africa/Cairo')::date) <= v_to
                            and (e.termination_date is null or e.termination_date > v_to)
                            and (e.status = 'active' or e.termination_date is not null)) as headcount,
         count(*) filter (where e.hire_date between p_from and v_to) as joined,
         count(*) filter (where e.termination_date between p_from and v_to) as left_n
    into v_hc from employees e;

  -- working days expected from today's staff (attendance-exempt people, rest days, holidays and approved leave left out)
  with emp as (
    select e.id, e.branch_id, coalesce(e.weekend_days, v_weekend) as wk, greatest(p_from, coalesce(e.hire_date, p_from)) as s
      from employees e
     where e.status = 'active' and not coalesce(e.attendance_exempt, false)
  ), dd as (
    select emp.id, g::date as d
      from emp cross join lateral generate_series(emp.s::timestamp, v_att_to::timestamp, interval '1 day') g
     where not (emp.wk @> to_jsonb(extract(dow from g)::int))
       and not exists (select 1 from holidays h where h.holiday_date = g::date and (h.branch_id is null or h.branch_id = emp.branch_id))
  )
  select count(*) filter (where not lv.on_leave) as expected
    into v_exp
    from dd cross join lateral (select exists (select 1 from leave_requests q where q.employee_id = dd.id and q.status = 'approved' and dd.d between q.start_date and q.end_date) as on_leave) lv;

  -- days worked and days late: HR's own count (kpi_attendance, the same one the KPI page uses)
  select coalesce(sum(x.worked_days), 0) as worked, coalesce(sum(x.late_days), 0) as late
    into v_att from public.kpi_attendance(p_from, v_att_to) x;

  -- leave days taken (approved, rest days left out) and leave requests made
  select count(*) into v_leave_days from (
    select distinct q.employee_id, g::date
      from leave_requests q
      join employees e on e.id = q.employee_id
     cross join lateral generate_series(greatest(q.start_date, p_from)::timestamp, least(q.end_date, p_to)::timestamp, interval '1 day') g
     where q.status = 'approved' and q.start_date <= p_to and q.end_date >= p_from
       and not (coalesce(e.weekend_days, v_weekend) @> to_jsonb(extract(dow from g)::int))) z;
  select count(*) into v_leave_req from leave_requests q where (q.created_at at time zone 'Africa/Cairo')::date between p_from and v_to;

  -- salary bill of the month p_to falls in: the approved payroll, else the employee cards (an estimate)
  select count(distinct pr_.id) as runs, coalesce(sum(i.gross_pay), 0) as gross, coalesce(sum(i.net_pay), 0) as net,
         coalesce(sum(i.insurance_employer), 0) as er, count(i.id) as people
    into v_pay
    from payroll_runs pr_ left join payroll_items i on i.run_id = pr_.id
   where pr_.status = 'approved' and pr_.year = extract(year from p_to)::int and pr_.month = extract(month from p_to)::int;
  select coalesce(sum(x.pay), 0) as total, count(*) filter (where x.pay > 0) as with_salary, count(*) as staff
    into v_card
    from (select coalesce(e.basic_salary, 0)
                 + coalesce((select sum(case when jsonb_typeof(al) = 'object' and coalesce(al ->> 'amount', '') ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
                                             then (al ->> 'amount')::numeric else 0 end)
                               from jsonb_array_elements(case when jsonb_typeof(e.allowances) = 'array' then e.allowances else '[]'::jsonb end) al), 0) as pay
            from employees e
           where coalesce(e.hire_date, (e.created_at at time zone 'Africa/Cairo')::date) <= v_to
             and (e.termination_date is null or e.termination_date > v_to)
             and (e.status = 'active' or e.termination_date is not null)) x;

  -- ===== WORK: Maintenance (a task is done when it was completed or reviewed)
  select count(*) filter (where coalesce(t.start_date, t.task_date, (t.created_at at time zone 'Africa/Cairo')::date) between p_from and v_to) as created,
         count(*) filter (where z.done_on between p_from and v_to) as done,
         count(*) filter (where z.done_on between p_from and v_to and coalesce(t.end_date, t.task_date) < z.done_on) as done_late
    into v_mt
    from hv_tasks t
   cross join lateral (select (coalesce(t.actual_completion_date, t.admin_revised_at, t.supervisor_revised_at) at time zone 'Africa/Cairo')::date as done_on) z;

  -- HV Ops listings (offline properties are not in the view) and tasks
  select count(*) filter (where (v.date_received at time zone 'Africa/Cairo')::date between p_from and v_to) as received,
         count(*) filter (where (v.date_published_verified at time zone 'Africa/Cairo')::date between p_from and v_to) as published,
         count(*) filter (where (v.date_published_verified at time zone 'Africa/Cairo')::date between p_from and v_to and v.is_on_time) as on_time,
         round(avg(v.hours_to_publish) filter (where (v.date_published_verified at time zone 'Africa/Cairo')::date between p_from and v_to), 1) as avg_hours
    into v_ol from ops_vw_listing_sla v;
  select count(*) filter (where (x.completed_at at time zone 'Africa/Cairo')::date between p_from and v_to) as done,
         count(*) filter (where (x.completed_at at time zone 'Africa/Cairo')::date between p_from and v_to and x.due_at is not null and x.completed_at > x.due_at) as done_late
    into v_ot from ops_tasks x;

  return jsonb_build_object(
    'from', p_from, 'to', p_to,
    'money', jsonb_build_object(
      'income', round(v_fl.income, 2), 'costs', round(v_fl.costs, 2), 'profit', round(v_fl.income - v_fl.costs, 2), 'entries', v_fl.entries,
      'hub', v_hub) || public.mgmt_money_at(v_to),
    'people', jsonb_build_object(
      'headcount', v_hc.headcount, 'joined', v_hc.joined, 'left', v_hc.left_n,
      'att_to', case when v_att_to >= p_from then v_att_to end,
      'expected_days', v_exp.expected, 'worked_days', v_att.worked, 'late_days', v_att.late,
      'attendance_pct', case when v_exp.expected > 0 then round(least(100, 100.0 * v_att.worked / v_exp.expected), 1) end,
      'late_pct', case when v_att.worked > 0 then round(100.0 * v_att.late / v_att.worked, 1) end,
      'leave_days', v_leave_days, 'leave_requests', v_leave_req,
      'salary', case when v_pay.runs > 0
                     then jsonb_build_object('source', 'payroll', 'total', round(v_pay.gross, 2), 'net', round(v_pay.net, 2), 'employer_insurance', round(v_pay.er, 2), 'people', v_pay.people)
                     else jsonb_build_object('source', 'cards', 'total', round(v_card.total, 2), 'with_salary', v_card.with_salary, 'staff', v_card.staff) end),
    'work', jsonb_build_object(
      'maint_created', v_mt.created, 'maint_done', v_mt.done, 'maint_done_late', v_mt.done_late,
      'listings_received', v_ol.received, 'listings_published', v_ol.published, 'listings_on_time', v_ol.on_time,
      'listings_on_time_pct', case when v_ol.published > 0 then round(100.0 * v_ol.on_time / v_ol.published, 1) end,
      'listings_avg_hours', v_ol.avg_hours,
      'ops_tasks_done', v_ot.done, 'ops_tasks_done_late', v_ot.done_late));
end;
$fn$;

-- ---------------------------------------------------------------- right now
create or replace function public.mgmt_now()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_today   date := (now() at time zone 'Africa/Cairo')::date;
  v_clock   time := (now() at time zone 'Africa/Cairo')::time;
  v_dow     int  := extract(dow from (now() at time zone 'Africa/Cairo'))::int;
  v_weekend jsonb := coalesce((select s.value -> 'weekend_days' from app_settings s where s.key = 'work_week'), '[5,6]'::jsonb);
  v_money jsonb; v_p record; v_m record; v_o record; v_t record; v_leave_waiting int;
begin
  -- ===== MONEY waiting in every system (HV Finance's "All systems" list)
  begin
    with h as (select * from public.fin_money_hub()),
         col as (select * from h where h.stage = 'to_collect' and h.open_amount > 0),
         pay as (select * from h where h.stage = 'to_pay' and h.open_amount > 0),
         nb as (select * from h where h.can_bring)
    select jsonb_build_object(
             'ok', true,
             'to_collect_n', (select count(*) from col),
             'to_collect', coalesce((select jsonb_object_agg(z.currency, z.s) from (select col.currency, round(sum(col.open_amount), 2) as s from col group by 1) z), '{}'::jsonb),
             'late_n', (select count(*) from col where col.due_date < v_today),
             'late', coalesce((select jsonb_object_agg(z.currency, z.s) from (select col.currency, round(sum(col.open_amount), 2) as s from col where col.due_date < v_today group by 1) z), '{}'::jsonb),
             'to_pay_n', (select count(*) from pay),
             'to_pay', coalesce((select jsonb_object_agg(z.currency, z.s) from (select pay.currency, round(sum(pay.open_amount), 2) as s from pay group by 1) z), '{}'::jsonb),
             'not_booked_n', (select count(*) from nb),
             'not_booked_in', coalesce((select jsonb_object_agg(z.currency, z.s) from (select nb.currency, round(sum(nb.amount), 2) as s from nb where nb.direction = 'in' group by 1) z), '{}'::jsonb),
             'not_booked_out', coalesce((select jsonb_object_agg(z.currency, z.s) from (select nb.currency, round(sum(nb.amount), 2) as s from nb where nb.direction = 'out' group by 1) z), '{}'::jsonb),
             'not_booked_old_n', (select count(*) from nb where nb.direction = 'in' and nb.doc_date < v_today - 7))
      into v_money;
  exception when others then
    v_money := jsonb_build_object('ok', false);
  end;

  -- ===== PEOPLE today: who is expected, who checked in, who is late, on leave, absent (shift start + grace passed)
  with emp as (
    select e.id, e.branch_id, e.shift_id, e.day_shifts, coalesce(e.weekend_days, v_weekend) as wk
      from employees e
     where e.status = 'active' and not coalesce(e.attendance_exempt, false)
       and coalesce(e.hire_date, v_today) <= v_today
  ), x as (
    select emp.id,
           (emp.wk @> to_jsonb(v_dow)
            or exists (select 1 from holidays h where h.holiday_date = v_today and (h.branch_id is null or h.branch_id = emp.branch_id))) as off_day,
           exists (select 1 from leave_requests q where q.employee_id = emp.id and q.status = 'approved' and v_today between q.start_date and q.end_date) as on_leave,
           -- start of this person's shift today + grace (same order as kpi_attendance)
           (coalesce((s.day_hours -> (v_dow::text) ->> 'start')::time, s.start_time,
                     (ds.day_hours -> (v_dow::text) ->> 'start')::time, ds.start_time)
            + make_interval(mins => coalesce(s.grace_minutes, ds.grace_minutes, 0))) as due_by,
           a.worked_days, a.late_days
      from emp
      left join shifts s on s.id = coalesce(case when (emp.day_shifts ->> v_dow::text) ~ '^[0-9a-f-]{36}$' then (emp.day_shifts ->> v_dow::text)::uuid end, emp.shift_id)
      left join lateral (select sh.start_time, sh.grace_minutes, sh.day_hours from shifts sh where sh.is_active order by sh.created_at limit 1) ds on true
      left join public.kpi_attendance(v_today, v_today) a on a.employee_id = emp.id
  )
  select count(*) filter (where not x.off_day and not x.on_leave) as expected,
         count(*) filter (where coalesce(x.worked_days, 0) > 0) as present,
         coalesce(sum(x.late_days), 0) as late,
         count(*) filter (where not x.off_day and x.on_leave) as on_leave,
         count(*) filter (where not x.off_day and not x.on_leave and coalesce(x.worked_days, 0) = 0 and x.due_by is not null and v_clock > x.due_by) as absent,
         count(*) filter (where not x.off_day and not x.on_leave and coalesce(x.worked_days, 0) = 0 and (x.due_by is null or v_clock <= x.due_by)) as not_yet
    into v_p from x;
  select count(*) into v_leave_waiting from leave_requests q where q.status in ('pending', 'manager_approved');

  -- ===== WORK: Maintenance, the same rules as its alerts (hv_alerts_maint, seen by a senior reviewer)
  with a as (
    select t.id, t.submitted_at, t.admin_revised_at, t.supervisor_revised_at, t.actual_completion_date, t.employee_progress,
           coalesce(t.end_date, t.task_date) as e,
           coalesce((select array_agg((j #>> '{}')::bigint) from jsonb_array_elements(case when jsonb_typeof(t.assigned_to_multi) = 'array' and jsonb_array_length(t.assigned_to_multi) > 0 then t.assigned_to_multi else '[]'::jsonb end) j),
                    case when t.assigned_to is not null then array[t.assigned_to] else '{}'::bigint[] end) as ids
      from hv_tasks t
  ), b as (
    select a.*,
           (a.submitted_at is not null
            or (cardinality(a.ids) > 0 and not exists (
                  select 1 from unnest(a.ids) i join hv_users u on u.id = i and coalesce(u.is_active, true)
                   where coalesce(a.employee_progress -> i::text ->> 'submitted_at', '') = ''))) as full_sub
      from a
  )
  select count(*) filter (where b.admin_revised_at is null and b.full_sub) as review_admin,
         count(*) filter (where b.admin_revised_at is not null and b.supervisor_revised_at is null) as review_senior,
         count(*) filter (where b.actual_completion_date is null and b.supervisor_revised_at is null and b.admin_revised_at is null and not b.full_sub) as open_n,
         count(*) filter (where b.actual_completion_date is null and b.supervisor_revised_at is null and b.admin_revised_at is null and not b.full_sub and b.e < v_today) as late
    into v_m from b;

  -- HV Ops: listings not live yet, inside / past the publishing limit (ops_settings.sla_hours), and tasks
  select count(*) filter (where v.date_published_verified is null and v.sla_state in ('green', 'yellow')) as in_window,
         count(*) filter (where v.date_published_verified is null and v.sla_state = 'red') as breached,
         count(*) filter (where v.status = 'on_hold') as on_hold,
         count(*) filter (where v.claimed_not_found) as claimed_not_found
    into v_o from ops_vw_listing_sla v;
  select count(*) filter (where x.status::text not in ('done', 'cancelled')) as open_n,
         count(*) filter (where x.status::text not in ('done', 'cancelled') and x.due_at < now()) as overdue,
         count(*) filter (where x.status::text = 'review') as review
    into v_t from ops_tasks x;

  return jsonb_build_object(
    'today', v_today,
    'money', v_money || public.mgmt_money_at(v_today),
    'people', jsonb_build_object('expected', v_p.expected, 'present', v_p.present, 'late', v_p.late, 'on_leave', v_p.on_leave,
                                 'absent', v_p.absent, 'not_yet', v_p.not_yet, 'leave_waiting', v_leave_waiting,
                                 'headcount', (select count(*) from employees e where e.status = 'active')),
    'work', jsonb_build_object('maint_open', v_m.open_n, 'maint_late', v_m.late, 'maint_review', v_m.review_admin + v_m.review_senior,
                               'maint_review_admin', v_m.review_admin, 'maint_review_senior', v_m.review_senior,
                               'listings_in_window', v_o.in_window, 'listings_breached', v_o.breached, 'listings_on_hold', v_o.on_hold,
                               'listings_claimed_not_found', v_o.claimed_not_found,
                               'ops_tasks_open', v_t.open_n, 'ops_tasks_overdue', v_t.overdue, 'ops_tasks_review', v_t.review));
end;
$fn$;

-- ---------------------------------------------------------------- the two calls the app makes
-- this period + the same span one month earlier (a whole month -> the whole month before) + right now
create or replace function public.mgmt_overview(p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_from date; v_to date; v_pf date; v_pt date;
begin
  perform public.mgmt_require();
  v_from := coalesce(p_from, date_trunc('month', v_today)::date);
  v_to := coalesce(p_to, v_today);
  if v_from > v_to then raise exception 'BAD_PERIOD: the start is after the end'; end if;
  if v_to - v_from > 400 then raise exception 'BAD_PERIOD: at most 400 days'; end if;
  v_pf := (v_from - interval '1 month')::date;
  v_pt := case when v_to = (date_trunc('month', v_to) + interval '1 month - 1 day')::date
               then (date_trunc('month', v_to) - interval '1 day')::date
               else (v_to - interval '1 month')::date end;
  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'prev_from', v_pf, 'prev_to', v_pt, 'today', v_today, 'at', now(),
    'cur', public.mgmt_period(v_from, v_to),
    'prev', public.mgmt_period(v_pf, v_pt),
    'now', public.mgmt_now());
end;
$fn$;

-- one entry per month (oldest first, this month last and only up to today) for the small trend lines
create or replace function public.mgmt_trend(p_months int default 6)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_n int := least(greatest(coalesce(p_months, 6), 1), 24);
  v_out jsonb := '[]'::jsonb;
  v_m date; v_end date;
begin
  perform public.mgmt_require();
  for i in reverse (v_n - 1)..0 loop
    v_m := (date_trunc('month', v_today) - make_interval(months => i))::date;
    v_end := least((v_m + interval '1 month - 1 day')::date, v_today);
    v_out := v_out || jsonb_build_array(jsonb_build_object('month', to_char(v_m, 'YYYY-MM')) || public.mgmt_period(v_m, v_end));
  end loop;
  return v_out;
end;
$fn$;

-- ---------------------------------------------------------------- the 🏢 switcher and the 🔔 bell
create or replace function public.hv_my_systems()
returns jsonb language sql stable security definer set search_path = public as $fn$
  select coalesce((
    select jsonb_build_object(
      'hr',    a.is_active and coalesce(a.access_hr, false),
      'maint', a.is_active and coalesce(a.access_maint, false),
      'crm',   a.is_active and coalesce(a.access_crm, false),
      'ops',   a.is_active and coalesce(a.access_ops, false),
      'fin',   a.is_active and coalesce(a.access_fin, false),
      'mgmt',  a.is_active and coalesce(a.access_mgmt, false) and a.role = 'ceo')
    from public.app_users a where a.id = auth.uid()
  ), '{"hr":false,"maint":false,"crm":false,"ops":false,"fin":false,"mgmt":false}'::jsonb)
$fn$;

-- what HV Management flags for the CEO (things only an overview shows)
create or replace function public.hv_alerts_mgmt(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_items jsonb := '[]'::jsonb;
  v_n int;
  v_pos jsonb;
  v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  if not public.mgmt_allowed(p_uid) then return null; end if;
  begin
    v_pos := public.mgmt_money_at(v_today);
    if (v_pos ->> 'owners_held_egp')::numeric > (v_pos ->> 'cash_egp')::numeric + 1 then
      v_items := v_items || jsonb_build_object('en', 'Owners'' money is more than the cash we hold', 'ar', 'أموال الملاك أكبر من النقدية لدينا', 'n', 1, 'page', 'home', 'action', 'money');
    end if;
  exception when others then null;
  end;
  begin
    select count(*) into v_n from ops_vw_listing_sla v where v.date_published_verified is null and v.sla_state = 'red';
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Listings past the publishing time limit', 'ar', 'إعلانات تجاوزت مهلة النشر', 'n', v_n, 'page', 'home', 'action', 'work'); end if;
  exception when others then null;
  end;
  if p_uid = auth.uid() then
    begin
      select count(*) into v_n from public.fin_money_hub() h where h.can_bring and h.direction = 'in' and h.doc_date < v_today - 7;
      if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Money collected but not in the books for over a week', 'ar', 'أموال محصّلة لم تُسجَّل في الحسابات منذ أكثر من أسبوع', 'n', 1, 'page', 'home', 'action', 'money'); end if;
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('n', (select coalesce(sum((x ->> 'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$fn$;

-- same as migration_050 + the mgmt line
create or replace function public.hv_alert_counts()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_out jsonb := '{}'::jsonb;
  v_part jsonb;
begin
  if v_uid is null then return v_out; end if;
  begin v_part := public.hv_alerts_hr(v_uid);    if v_part is not null then v_out := v_out || jsonb_build_object('hr', v_part); end if;    exception when others then null; end;
  begin v_part := public.hv_alerts_maint(v_uid); if v_part is not null then v_out := v_out || jsonb_build_object('maint', v_part); end if; exception when others then null; end;
  begin v_part := public.hv_alerts_crm(v_uid);   if v_part is not null then v_out := v_out || jsonb_build_object('crm', v_part); end if;   exception when others then null; end;
  begin v_part := public.hv_alerts_ops(v_uid);   if v_part is not null then v_out := v_out || jsonb_build_object('ops', v_part); end if;   exception when others then null; end;
  begin v_part := public.hv_alerts_fin(v_uid);   if v_part is not null then v_out := v_out || jsonb_build_object('fin', v_part); end if;   exception when others then null; end;
  begin v_part := public.hv_alerts_mgmt(v_uid);  if v_part is not null then v_out := v_out || jsonb_build_object('mgmt', v_part); end if;  exception when others then null; end;
  return v_out;
end;
$fn$;

-- ---------------------------------------------------------------- who may call what
revoke all on function public.mgmt_allowed(uuid), public.mgmt_require(), public.mgmt_access_guard(), public.mgmt_money_at(date),
                       public.mgmt_period(date, date), public.mgmt_now(), public.hv_alerts_mgmt(uuid) from public, anon, authenticated;
revoke all on function public.mgmt_overview(date, date), public.mgmt_trend(int), public.hv_my_systems(), public.hv_alert_counts() from public, anon;
grant execute on function public.mgmt_overview(date, date), public.mgmt_trend(int), public.hv_my_systems(), public.hv_alert_counts() to authenticated;

-- ---------------------------------------------------------------- Daniel (2026-10-18): all three CEOs get HV Management
update public.app_users set access_mgmt = true where role = 'ceo' and is_active and not access_mgmt;

notify pgrst, 'reload schema';
