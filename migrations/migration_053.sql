-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_053.sql
-- HV Management v1.1 (Daniel, 2026-10-19):
--   1. GIVE A TASK — the CEO picks the system and the task lands straight
--      in that system's own task list, exactly as if it was made there
--      (same columns, same notifications through the system's own
--      triggers): Maintenance (hv_tasks), HV Ops (ops_tasks), CRM
--      (tasks, per property). HR and HV Finance have no task list.
--      Every task given is remembered in mgmt_task_log so HV Management
--      can show its live status.
--   2. TEAM — each employee's numbers for a period: HR KPI points and
--      results, tasks done / late / open / overdue (Maintenance + HV
--      Ops), entries made (HV Ops listings and projects, HV Finance
--      documents, maintenance estimates, KPI results recorded) and
--      attendance. For each DEPARTMENT the CEO chooses which numbers
--      count (mgmt_dept_metrics); until then a default per department.
-- Everything goes through mgmt_ functions that refuse anyone who is not
-- an active CEO with the HV Management tick (mgmt_require, migration_052).
-- ADDITIVE ONLY. Safe to re-run. Run after 052.
-- =====================================================================

-- ---------------------------------------------------------------- tables owned by HV Management
create table if not exists public.mgmt_dept_metrics (
  dept_key   text primary key,                 -- departments.id as text, or 'none' for people without a department
  metrics    text[] not null default '{}',
  updated_by uuid,
  updated_at timestamptz not null default now()
);
alter table public.mgmt_dept_metrics enable row level security;   -- no policies: only through the mgmt_ functions

create table if not exists public.mgmt_task_log (
  id         uuid primary key default gen_random_uuid(),
  system     text not null check (system in ('maint', 'ops', 'crm')),
  target_id  text not null,
  title      text,
  assignees  text,
  due        date,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists mgmt_task_log_created on public.mgmt_task_log (created_at desc);
alter table public.mgmt_task_log enable row level security;

-- ---------------------------------------------------------------- the numbers a CEO can choose from
create or replace function public.mgmt_metric_catalog()
returns jsonb language sql stable security definer set search_path = public as $fn$
  select jsonb_build_array(
    jsonb_build_object('key', 'kpi_points',        'group', 'kpi',        'good', 'up',   'unit', 'pts', 'en', 'KPI points',                    'ar', 'نقاط مؤشرات الأداء'),
    jsonb_build_object('key', 'tasks_done',        'group', 'tasks',      'good', 'up',   'unit', '',    'en', 'Tasks done',                    'ar', 'مهام منجزة'),
    jsonb_build_object('key', 'tasks_done_late',   'group', 'tasks',      'good', 'down', 'unit', '',    'en', 'Tasks done late',               'ar', 'مهام أُنجزت متأخرة'),
    jsonb_build_object('key', 'tasks_on_time_pct', 'group', 'tasks',      'good', 'up',   'unit', '%',   'en', 'Tasks on time',                 'ar', 'المهام في موعدها'),
    jsonb_build_object('key', 'tasks_open',        'group', 'tasks',      'good', null,   'unit', '',    'en', 'Open tasks (now)',              'ar', 'مهام مفتوحة (الآن)'),
    jsonb_build_object('key', 'tasks_overdue',     'group', 'tasks',      'good', 'down', 'unit', '',    'en', 'Overdue tasks (now)',           'ar', 'مهام متأخرة (الآن)'),
    jsonb_build_object('key', 'entries_listings',  'group', 'entries',    'good', 'up',   'unit', '',    'en', 'Listings & projects entered',   'ar', 'وحدات ومشروعات أُدخلت'),
    jsonb_build_object('key', 'entries_finance',   'group', 'entries',    'good', 'up',   'unit', '',    'en', 'Finance documents entered',     'ar', 'مستندات حسابات أُدخلت'),
    jsonb_build_object('key', 'entries_maint',     'group', 'entries',    'good', 'up',   'unit', '',    'en', 'Maintenance estimates entered', 'ar', 'مقايسات صيانة أُدخلت'),
    jsonb_build_object('key', 'entries_kpi',       'group', 'entries',    'good', 'up',   'unit', '',    'en', 'KPI results recorded',          'ar', 'نتائج مؤشرات سُجّلت'),
    jsonb_build_object('key', 'att_pct',           'group', 'attendance', 'good', 'up',   'unit', '%',   'en', 'Attendance',                    'ar', 'نسبة الحضور'),
    jsonb_build_object('key', 'late_days',         'group', 'attendance', 'good', 'down', 'unit', '',    'en', 'Days late',                     'ar', 'أيام التأخير'),
    jsonb_build_object('key', 'absent_days',       'group', 'attendance', 'good', 'down', 'unit', '',    'en', 'Days absent',                   'ar', 'أيام الغياب'),
    jsonb_build_object('key', 'leave_days',        'group', 'attendance', 'good', null,   'unit', '',    'en', 'Leave days',                    'ar', 'أيام الإجازة'))
  || coalesce((select jsonb_agg(jsonb_build_object('key', 'kpi:' || m.code, 'group', 'kpi', 'good', 'up', 'unit', '',
                                                   'en', m.name_en, 'ar', m.name_ar, 'category', m.category) order by m.sort, m.code)
                 from kpi_metrics m where m.is_active), '[]'::jsonb)
$fn$;

-- what a department shows until the CEO chooses (by the department's name)
create or replace function public.mgmt_default_metrics(p_name text)
returns text[] language sql immutable as $fn$
  select case
    when p_name ~* 'sales|مبيعات'               then array['kpi_points','kpi:lead','kpi:viewing','kpi:offer','kpi:closing','kpi:rental','att_pct','late_days']
    when p_name ~* 'marketing|تسويق'            then array['entries_listings','tasks_done','tasks_overdue','kpi_points','att_pct','late_days']
    when p_name ~* 'finance|account|مالي|حسابات' then array['entries_finance','tasks_done','tasks_overdue','att_pct','late_days']
    when p_name ~* 'operation|عمليات'           then array['tasks_done','tasks_done_late','tasks_overdue','entries_maint','kpi_points','att_pct','late_days']
    when p_name ~* 'hr|admin|موارد|إدار'        then array['tasks_done','tasks_overdue','entries_kpi','att_pct','late_days','leave_days']
    when p_name ~* 'customer|خدمة'              then array['kpi_points','tasks_done','tasks_overdue','att_pct','late_days']
    else array['kpi_points','tasks_done','tasks_overdue','att_pct','late_days'] end
$fn$;

-- ---------------------------------------------------------------- every number of every active employee for one period
-- { "<employee id>": { "kpi_points": 12.5, "kpi:closing": 1, "tasks_done": 4, … } }
create or replace function public.mgmt_team_values(p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_today   date := (now() at time zone 'Africa/Cairo')::date;
  v_to      date := least(p_to, v_today);
  v_att_to  date := case when p_to >= v_today then v_today - 1 else p_to end;
  v_weekend jsonb := coalesce((select s.value -> 'weekend_days' from app_settings s where s.key = 'work_week'), '[5,6]'::jsonb);
  v_out jsonb;
begin
  if p_from is null or p_to is null or p_from > p_to then raise exception 'BAD_PERIOD'; end if;
  with emp as (
    select e.id, e.user_id, e.branch_id, coalesce(e.attendance_exempt, false) as exempt, coalesce(e.weekend_days, v_weekend) as wk,
           greatest(p_from, coalesce(e.hire_date, p_from)) as s
      from employees e where e.status = 'active'
  ),
  hvu as (   -- the person's Maintenance account(s)
    select emp.id as emp_id, u.id as hv_id, u.name as hv_name
      from emp join hv_users u on u.employee_id = emp.id or (emp.user_id is not null and u.auth_user_id = emp.user_id)
  ),
  -- KPI: approved results in the period, HR's own scoring
  kpi_rows as (
    select k.employee_id as emp_id, m.code, sum(coalesce(k.quantity, 0)) as qty,
           sum(coalesce(k.quantity, 0) * coalesce(m.points_per_unit, 0) + coalesce(k.value_egp, 0) / 1000000.0 * coalesce(m.value_points_per_million, 0)) as pts
      from kpi_entries k join kpi_metrics m on m.id = k.metric_id
     where k.status = 'approved' and k.entry_date between p_from and v_to
     group by 1, 2
  ),
  kpi as (select r.emp_id, sum(r.pts) as points, jsonb_object_agg('kpi:' || r.code, r.qty) as counts from kpi_rows r group by r.emp_id),
  -- Maintenance tasks of each assignee (a task done = completed or reviewed)
  mt as (
    select t.id, (coalesce(t.actual_completion_date, t.admin_revised_at, t.supervisor_revised_at) at time zone 'Africa/Cairo')::date as done_on,
           coalesce(t.end_date, t.task_date) as e,
           coalesce((select array_agg((j #>> '{}')::bigint) from jsonb_array_elements(case when jsonb_typeof(t.assigned_to_multi) = 'array' and jsonb_array_length(t.assigned_to_multi) > 0 then t.assigned_to_multi else '[]'::jsonb end) j),
                    case when t.assigned_to is not null then array[t.assigned_to] else '{}'::bigint[] end) as ids,
           (t.submitted_at is not null) as submitted
      from hv_tasks t
  ),
  mtask as (
    select h.emp_id,
           count(distinct mt.id) filter (where mt.done_on between p_from and v_to) as done,
           count(distinct mt.id) filter (where mt.done_on between p_from and v_to and mt.e < mt.done_on) as done_late,
           count(distinct mt.id) filter (where mt.done_on is null and not mt.submitted) as open_n,
           count(distinct mt.id) filter (where mt.done_on is null and not mt.submitted and mt.e < v_today) as overdue
      from hvu h join mt on h.hv_id = any (mt.ids)
     group by h.emp_id
  ),
  otask as (
    select emp.id as emp_id,
           count(*) filter (where (x.completed_at at time zone 'Africa/Cairo')::date between p_from and v_to) as done,
           count(*) filter (where (x.completed_at at time zone 'Africa/Cairo')::date between p_from and v_to and x.due_at is not null and x.completed_at > x.due_at) as done_late,
           count(*) filter (where x.status::text not in ('done', 'cancelled', 'review')) as open_n,
           count(*) filter (where x.status::text not in ('done', 'cancelled', 'review') and x.due_at < now()) as overdue
      from emp join ops_tasks x on x.assigned_to = emp.user_id
     group by emp.id
  ),
  ent as (
    select emp.id as emp_id,
           (select count(*) from ops_listings l where l.entered_by = emp.user_id and (l.date_received at time zone 'Africa/Cairo')::date between p_from and v_to)
         + (select count(*) from ops_projects l where l.entered_by = emp.user_id and (l.date_received at time zone 'Africa/Cairo')::date between p_from and v_to) as listings,
           (select count(*) from fin_vouchers v where v.created_by = emp.user_id and (v.created_at at time zone 'Africa/Cairo')::date between p_from and v_to)
         + (select count(*) from fin_invoices v where v.created_by = emp.user_id and (v.created_at at time zone 'Africa/Cairo')::date between p_from and v_to)
         + (select count(*) from fin_bills v where v.created_by = emp.user_id and (v.created_at at time zone 'Africa/Cairo')::date between p_from and v_to)
         + (select count(*) from fin_journals j where j.created_by = emp.user_id and j.source_table is null and j.kind not in ('receipt', 'payment', 'transfer', 'invoice', 'bill', 'reversal')
                                                    and (j.created_at at time zone 'Africa/Cairo')::date between p_from and v_to) as finance,
           (select count(*) from hv_invoices i where i.created_by in (select h.hv_name from hvu h where h.emp_id = emp.id) and (i.created_at at time zone 'Africa/Cairo')::date between p_from and v_to) as maint,
           (select count(*) from kpi_entries k where k.created_by = emp.user_id and (k.created_at at time zone 'Africa/Cairo')::date between p_from and v_to) as kpi
      from emp where emp.user_id is not null
  ),
  dd as (   -- working days expected (rest days, holidays, approved leave and attendance-exempt people left out)
    select emp.id as emp_id, g::date as d,
           exists (select 1 from leave_requests q where q.employee_id = emp.id and q.status = 'approved' and g::date between q.start_date and q.end_date) as on_leave
      from emp cross join lateral generate_series(emp.s::timestamp, v_att_to::timestamp, interval '1 day') g
     where not emp.exempt
       and not (emp.wk @> to_jsonb(extract(dow from g)::int))
       and not exists (select 1 from holidays h where h.holiday_date = g::date and (h.branch_id is null or h.branch_id = emp.branch_id))
  ),
  expd as (select dd.emp_id, count(*) filter (where not dd.on_leave) as expected from dd group by dd.emp_id),
  att as (select a.employee_id as emp_id, a.worked_days, a.late_days from public.kpi_attendance(p_from, v_att_to) a),
  lv as (
    select q.employee_id as emp_id, count(distinct g::date) as days
      from leave_requests q join emp on emp.id = q.employee_id
     cross join lateral generate_series(greatest(q.start_date, p_from)::timestamp, least(q.end_date, p_to)::timestamp, interval '1 day') g
     where q.status = 'approved' and q.start_date <= p_to and q.end_date >= p_from
       and not (emp.wk @> to_jsonb(extract(dow from g)::int))
     group by q.employee_id
  )
  select coalesce(jsonb_object_agg(emp.id, v.vals), '{}'::jsonb) into v_out
    from emp
    left join kpi on kpi.emp_id = emp.id
    left join mtask on mtask.emp_id = emp.id
    left join otask on otask.emp_id = emp.id
    left join ent on ent.emp_id = emp.id
    left join expd on expd.emp_id = emp.id
    left join att on att.emp_id = emp.id
    left join lv on lv.emp_id = emp.id
   cross join lateral (
     select jsonb_strip_nulls(jsonb_build_object(
       'kpi_points', round(coalesce(kpi.points, 0), 2),
       'tasks_done', coalesce(mtask.done, 0) + coalesce(otask.done, 0),
       'tasks_done_late', coalesce(mtask.done_late, 0) + coalesce(otask.done_late, 0),
       'tasks_on_time_pct', case when coalesce(mtask.done, 0) + coalesce(otask.done, 0) > 0
                                 then round(100.0 * (coalesce(mtask.done, 0) + coalesce(otask.done, 0) - coalesce(mtask.done_late, 0) - coalesce(otask.done_late, 0))
                                            / (coalesce(mtask.done, 0) + coalesce(otask.done, 0)), 1) end,
       'tasks_open', coalesce(mtask.open_n, 0) + coalesce(otask.open_n, 0),
       'tasks_overdue', coalesce(mtask.overdue, 0) + coalesce(otask.overdue, 0),
       'maint_done', coalesce(mtask.done, 0), 'ops_done', coalesce(otask.done, 0),
       'entries_listings', coalesce(ent.listings, 0), 'entries_finance', coalesce(ent.finance, 0),
       'entries_maint', coalesce(ent.maint, 0), 'entries_kpi', coalesce(ent.kpi, 0),
       'att_pct', case when emp.exempt then null when coalesce(expd.expected, 0) > 0 then round(least(100, 100.0 * coalesce(att.worked_days, 0) / expd.expected), 1) end,
       'worked_days', case when emp.exempt then null else coalesce(att.worked_days, 0) end,
       'late_days', case when emp.exempt then null else coalesce(att.late_days, 0) end,
       'absent_days', case when emp.exempt then null else greatest(coalesce(expd.expected, 0) - coalesce(att.worked_days, 0), 0) end,
       'leave_days', coalesce(lv.days, 0))) || coalesce(kpi.counts, '{}'::jsonb) as vals
   ) v;
  return v_out;
end;
$fn$;

-- ---------------------------------------------------------------- TEAM: the call the app makes
create or replace function public.mgmt_team(p_from date default null, p_to date default null)
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
    'from', v_from, 'to', v_to, 'prev_from', v_pf, 'prev_to', v_pt, 'today', v_today,
    'catalog', public.mgmt_metric_catalog(),
    'departments', (
      select coalesce(jsonb_agg(jsonb_build_object('key', x.key, 'name_en', x.name_en, 'name_ar', x.name_ar, 'metrics', to_jsonb(coalesce(s.metrics, public.mgmt_default_metrics(x.name_en || ' ' || x.name_ar))), 'custom', s.dept_key is not null) order by x.ord, x.name_en), '[]'::jsonb)
        from (select d.id::text as key, d.name_en, d.name_ar, 0 as ord from departments d where d.is_active
              union all select 'none', 'No department', 'بدون قسم', 1) x
        left join mgmt_dept_metrics s on s.dept_key = x.key),
    'employees', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'code', e.employee_code, 'name_en', e.full_name_en, 'name_ar', e.full_name_ar,
                                                   'job_en', e.job_title_en, 'job_ar', e.job_title_ar, 'dept_key', coalesce(e.department_id::text, 'none'),
                                                   'exempt', coalesce(e.attendance_exempt, false)) order by e.full_name_en), '[]'::jsonb)
        from employees e where e.status = 'active'),
    'cur', public.mgmt_team_values(v_from, v_to),
    'prev', public.mgmt_team_values(v_pf, v_pt));
end;
$fn$;

-- the CEO chooses the numbers of a department; null / empty = back to the default
create or replace function public.mgmt_set_dept_metrics(p_dept_key text, p_metrics text[])
returns jsonb language plpgsql volatile security definer set search_path = public as $fn$
declare
  v_bad text;
begin
  perform public.mgmt_require();
  if p_dept_key is null or (p_dept_key <> 'none' and not exists (select 1 from departments d where d.id::text = p_dept_key)) then
    raise exception 'UNKNOWN_DEPARTMENT';
  end if;
  if p_metrics is null or cardinality(p_metrics) = 0 then
    delete from mgmt_dept_metrics where dept_key = p_dept_key;     -- a setting row, not data: back to the default
    return jsonb_build_object('dept_key', p_dept_key, 'custom', false);
  end if;
  select m into v_bad from unnest(p_metrics) m
   where m not in (select c ->> 'key' from jsonb_array_elements(public.mgmt_metric_catalog()) c) limit 1;
  if v_bad is not null then raise exception 'UNKNOWN_METRIC: %', v_bad; end if;
  insert into mgmt_dept_metrics (dept_key, metrics, updated_by, updated_at)
  values (p_dept_key, (select array_agg(distinct_m order by ord) from (select m as distinct_m, min(o) as ord from unnest(p_metrics) with ordinality u(m, o) group by m) z), auth.uid(), now())
  on conflict (dept_key) do update set metrics = excluded.metrics, updated_by = excluded.updated_by, updated_at = excluded.updated_at;
  return jsonb_build_object('dept_key', p_dept_key, 'custom', true);
end;
$fn$;

-- ---------------------------------------------------------------- GIVE A TASK: the lists the form needs
create or replace function public.mgmt_task_options()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
begin
  perform public.mgmt_require();
  return jsonb_build_object(
    'maint', jsonb_build_object(
      'types', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'subtasks', coalesce(t.subtasks, '[]'::jsonb)) order by t.title), '[]'::jsonb) from hv_task_types t),
      'properties', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name), '[]'::jsonb) from hv_properties p),
      'stores', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]'::jsonb) from hv_stores s),
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'role', u.role) order by u.name), '[]'::jsonb) from hv_users u where coalesce(u.is_active, true))),
    'ops', jsonb_build_object(
      'types', coalesce((select s.value from ops_settings s where s.key = 'task_types'), '[]'::jsonb),
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', coalesce(nullif(a.full_name_en, ''), a.username), 'name_ar', a.full_name_ar) order by a.full_name_en), '[]'::jsonb)
                   from app_users a where a.is_active and coalesce(a.access_ops, false))),
    'crm', jsonb_build_object(
      'properties', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name), '[]'::jsonb) from properties p)));
end;
$fn$;

-- ---------------------------------------------------------------- GIVE A TASK: write it into the chosen system
-- p_task (maint): { task_type_id, location_type, property_id?, source_store?, destination_store?, people: [hv_users ids],
--                   start_date, end_date?, notes?, subtasks?: [text] }
-- p_task (ops):   { title, description?, task_type?, assigned_to (app_users id), priority?, due_at? }
-- p_task (crm):   { property_id, title, task_type?, start_date, end_date?, priority?, notes? }
create or replace function public.mgmt_give_task(p_system text, p_task jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_by text; v_id text; v_title text; v_names text; v_due date;
  v_type hv_task_types%rowtype; v_loc text; v_prop bigint; v_src bigint; v_dst bigint; v_people bigint[]; v_start date; v_end date; v_subs jsonb;
  v_assignee uuid; v_prio text; v_due_at timestamptz; v_cprop uuid; v_ctype text;
begin
  perform public.mgmt_require();
  select coalesce((select u.name from hv_users u where u.auth_user_id = v_uid limit 1), nullif(a.full_name_ar, ''), a.full_name_en, a.username)
    into v_by from app_users a where a.id = v_uid;

  if p_system = 'maint' then
    select * into v_type from hv_task_types where id = (p_task ->> 'task_type_id')::bigint;
    if v_type.id is null then raise exception 'TASK_TYPE_REQUIRED'; end if;
    v_loc := coalesce(nullif(p_task ->> 'location_type', ''), 'unit_only');
    if v_loc not in ('unit_only', 'store_only', 'store_to_unit', 'unit_to_store', 'store_to_store', 'general') then raise exception 'BAD_LOCATION_TYPE'; end if;
    v_prop := nullif(p_task ->> 'property_id', '')::bigint; v_src := nullif(p_task ->> 'source_store', '')::bigint; v_dst := nullif(p_task ->> 'destination_store', '')::bigint;
    if v_loc in ('unit_only', 'store_to_unit', 'unit_to_store') and not exists (select 1 from hv_properties where id = v_prop) then raise exception 'PROPERTY_REQUIRED'; end if;
    if v_loc in ('store_only', 'store_to_unit', 'store_to_store') and not exists (select 1 from hv_stores where id = v_src) then raise exception 'STORE_REQUIRED'; end if;
    if v_loc in ('unit_to_store', 'store_to_store') and not exists (select 1 from hv_stores where id = v_dst) then raise exception 'STORE_REQUIRED'; end if;
    if v_loc = 'store_to_store' and v_src = v_dst then raise exception 'SAME_STORE'; end if;
    if v_loc not in ('unit_only', 'store_to_unit', 'unit_to_store') then v_prop := null; end if;
    if v_loc not in ('store_only', 'store_to_unit', 'store_to_store') then v_src := null; end if;
    if v_loc not in ('unit_to_store', 'store_to_store') then v_dst := null; end if;
    select array_agg(distinct (x #>> '{}')::bigint) into v_people from jsonb_array_elements(coalesce(p_task -> 'people', '[]'::jsonb)) x;
    if v_people is null or exists (select 1 from unnest(v_people) i where not exists (select 1 from hv_users u where u.id = i and coalesce(u.is_active, true))) then raise exception 'ASSIGNEE_REQUIRED'; end if;
    v_start := coalesce(nullif(p_task ->> 'start_date', '')::date, v_today);
    v_end := coalesce(nullif(p_task ->> 'end_date', '')::date, v_start);
    if v_end < v_start then raise exception 'END_BEFORE_START'; end if;
    v_subs := case when jsonb_typeof(p_task -> 'subtasks') = 'array' and jsonb_array_length(p_task -> 'subtasks') > 0 then p_task -> 'subtasks' else coalesce(v_type.subtasks, '[]'::jsonb) end;
    if jsonb_array_length(v_subs) = 0 then raise exception 'SUBTASK_REQUIRED'; end if;
    insert into hv_tasks (task_type_id, location_type, property_id, source_store, destination_store, assigned_to, assigned_to_multi,
                          task_date, start_date, end_date, is_range, admin_notes, checked_subtasks, employee_progress, final_revision_by_employee,
                          employee_notes, extra_work, custom_subtasks, audit_trail, recurrence_config)
    values (v_type.id, v_loc, v_prop, v_src, v_dst, v_people[1], to_jsonb(v_people),
            v_start, v_start, v_end, v_end > v_start, coalesce(p_task ->> 'notes', ''), '[]'::jsonb, '{}'::jsonb, false,
            '', '', v_subs,
            jsonb_build_array(jsonb_build_object('action', 'إنشاء المهمة من HV Management' || case when v_end > v_start then ' (' || v_start || ' → ' || v_end || ')' else '' end || ' مع ' || jsonb_array_length(v_subs) || ' بنود',
                                                 'by', v_by, 'timestamp', now())),
            null)
    returning id::text into v_id;
    v_title := v_type.title; v_due := v_end;
    select string_agg(u.name, ', ' order by u.name) into v_names from hv_users u where u.id = any (v_people);

  elsif p_system = 'ops' then
    v_title := btrim(coalesce(p_task ->> 'title', ''));
    if v_title = '' then raise exception 'TITLE_REQUIRED'; end if;
    v_assignee := nullif(p_task ->> 'assigned_to', '')::uuid;
    if v_assignee is null or not exists (select 1 from app_users a where a.id = v_assignee and a.is_active and coalesce(a.access_ops, false)) then raise exception 'ASSIGNEE_REQUIRED'; end if;
    v_prio := coalesce(nullif(p_task ->> 'priority', ''), 'normal');
    if v_prio not in ('low', 'normal', 'high', 'urgent') then raise exception 'BAD_PRIORITY'; end if;
    v_due_at := nullif(p_task ->> 'due_at', '')::timestamptz;
    insert into ops_tasks (title, description, task_type, assigned_to, priority, due_at, created_by)
    values (v_title, nullif(btrim(coalesce(p_task ->> 'description', '')), ''), nullif(p_task ->> 'task_type', ''), v_assignee, v_prio::ops_task_priority, v_due_at, v_uid)
    returning id::text into v_id;
    v_due := (v_due_at at time zone 'Africa/Cairo')::date;
    select coalesce(nullif(a.full_name_en, ''), a.username) into v_names from app_users a where a.id = v_assignee;

  elsif p_system = 'crm' then
    v_title := btrim(coalesce(p_task ->> 'title', ''));
    if v_title = '' then raise exception 'TITLE_REQUIRED'; end if;
    v_cprop := nullif(p_task ->> 'property_id', '')::uuid;
    if v_cprop is null or not exists (select 1 from properties where id = v_cprop) then raise exception 'PROPERTY_REQUIRED'; end if;
    v_ctype := coalesce(nullif(p_task ->> 'task_type', ''), 'other');
    if v_ctype not in ('cleaning', 'maintenance', 'inspection', 'collection', 'other') then raise exception 'BAD_TASK_TYPE'; end if;
    v_prio := coalesce(nullif(p_task ->> 'priority', ''), 'high');
    if v_prio not in ('normal', 'high', 'urgent') then raise exception 'BAD_PRIORITY'; end if;
    v_start := coalesce(nullif(p_task ->> 'start_date', '')::date, v_today);
    v_end := coalesce(nullif(p_task ->> 'end_date', '')::date, v_start);
    if v_end < v_start then raise exception 'END_BEFORE_START'; end if;
    insert into tasks (property_id, title, task_type, start_date, end_date, is_range, priority, status, notes)
    values (v_cprop, v_title, v_ctype, v_start, v_end, v_end > v_start, v_prio, 'pending', nullif(btrim(coalesce(p_task ->> 'notes', '')), ''))
    returning id::text into v_id;
    insert into activity (property_id, kind, description, at) values (v_cprop, 'task', 'مهمة من HV Management: ' || v_title, now());   -- the CRM's own log line
    v_due := v_end;
    select p.name into v_names from properties p where p.id = v_cprop;

  else
    raise exception 'UNKNOWN_SYSTEM';
  end if;

  insert into mgmt_task_log (system, target_id, title, assignees, due, created_by) values (p_system, v_id, v_title, v_names, v_due, v_uid);
  return jsonb_build_object('system', p_system, 'id', v_id, 'title', v_title, 'assignees', v_names);
end;
$fn$;

-- the tasks given from HV Management, with their live status in their own system
create or replace function public.mgmt_given_tasks(p_limit int default 40)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  perform public.mgmt_require();
  return (
    select coalesce(jsonb_agg(r order by (r ->> 'created_at') desc), '[]'::jsonb) from (
      select jsonb_build_object('id', g.id, 'system', g.system, 'target_id', g.target_id, 'title', g.title, 'assignees', g.assignees, 'due', g.due,
                                'created_at', g.created_at, 'by', coalesce(nullif(a.full_name_en, ''), a.username),
                                'status', case g.system
          when 'maint' then (select case when t.id is null then 'deleted'
                                         when t.actual_completion_date is not null or t.supervisor_revised_at is not null or t.admin_revised_at is not null then 'done'
                                         when t.submitted_at is not null then 'review'
                                         when coalesce(t.end_date, t.task_date) < v_today then 'late'
                                         when coalesce(t.start_date, t.task_date) <= v_today then 'in_progress' else 'open' end
                               from (select 1) z left join hv_tasks t on t.id::text = g.target_id)
          when 'ops' then (select case when x.id is null then 'deleted'
                                       when x.status::text = 'done' then 'done' when x.status::text = 'cancelled' then 'cancelled'
                                       when x.status::text = 'review' then 'review'
                                       when x.due_at < now() then 'late'
                                       when x.status::text = 'doing' then 'in_progress' else 'open' end
                             from (select 1) z left join ops_tasks x on x.id::text = g.target_id)
          when 'crm' then (select case when k.id is null then 'deleted' when k.status = 'done' then 'done'
                                       when k.end_date < v_today then 'late' else 'open' end
                             from (select 1) z left join tasks k on k.id::text = g.target_id)
        end) as r
        from mgmt_task_log g left join app_users a on a.id = g.created_by
       order by g.created_at desc
       limit least(greatest(coalesce(p_limit, 40), 1), 200)) s);
end;
$fn$;

-- ---------------------------------------------------------------- the 🔔: tasks the CEO gave that are now late
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
  begin
    select count(*) into v_n from mgmt_task_log g
     where g.created_by = p_uid and g.due < v_today
       and ((g.system = 'maint' and exists (select 1 from hv_tasks t where t.id::text = g.target_id and t.actual_completion_date is null and t.admin_revised_at is null and t.supervisor_revised_at is null and t.submitted_at is null))
         or (g.system = 'ops' and exists (select 1 from ops_tasks x where x.id::text = g.target_id and x.status::text not in ('done', 'cancelled', 'review')))
         or (g.system = 'crm' and exists (select 1 from tasks k where k.id::text = g.target_id and k.status <> 'done')));
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Tasks you gave that are late', 'ar', 'مهام أعطيتها ومتأخرة', 'n', v_n, 'page', 'tasks', 'action', 'given'); end if;
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

-- ---------------------------------------------------------------- who may call what
revoke all on function public.mgmt_metric_catalog(), public.mgmt_default_metrics(text), public.mgmt_team_values(date, date), public.hv_alerts_mgmt(uuid)
  from public, anon, authenticated;
revoke all on function public.mgmt_team(date, date), public.mgmt_set_dept_metrics(text, text[]), public.mgmt_task_options(),
                       public.mgmt_give_task(text, jsonb), public.mgmt_given_tasks(int) from public, anon;
grant execute on function public.mgmt_team(date, date), public.mgmt_set_dept_metrics(text, text[]), public.mgmt_task_options(),
                          public.mgmt_give_task(text, jsonb), public.mgmt_given_tasks(int) to authenticated;
revoke all on table public.mgmt_dept_metrics, public.mgmt_task_log from anon, authenticated;

notify pgrst, 'reload schema';
