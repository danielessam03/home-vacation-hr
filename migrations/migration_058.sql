-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_058.sql
-- HV Management DAILY REPORT (Daniel, 2026-10-27): "daily reports of all
-- entries and tasks done of the day and any activities done".
-- public.mgmt_day_report(p_day) returns, for one day (Egypt time):
--   entries   every new record made that day in every system (KPI
--             results, leave requests, tasks, receipts / invoices /
--             bills / journals, listings, projects, photo shoots,
--             maintenance tasks and estimates, CRM bookings and tasks,
--             rent / deposits collected), with who made it
--   done      every task finished that day (Maintenance submitted /
--             completed / reviewed, HV Ops done and approved, listings
--             published and live, CRM, HR and Finance tasks, photo
--             shoots), with who and whether it was late
--   timeline  every logged action of the day: HR + Finance audit log,
--             HV Ops change log, Maintenance task log, comments and
--             files, CRM activity — plus the entries / done items of
--             tables that keep no log
--   people    every active employee: first check-in, last check-out,
--             late / on leave, and their counts of entries, tasks done
--             and actions
--   summary   counts per system
-- Read-only, CEO-only (mgmt_require, migration_052). Nothing is stored:
-- any past day can be opened.
-- ADDITIVE ONLY. Safe to re-run. Run after 057.
-- =====================================================================

-- the report itself (internal: only the server and mgmt_day_report call it)
create or replace function public.mgmt_day_data(p_day date)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_day   date := coalesce(p_day, (now() at time zone 'Africa/Cairo')::date);
  v_from  timestamptz;
  v_to    timestamptz;
  v_max   int := 1500;
  v_out   jsonb;
begin
  if v_day > v_today then raise exception 'BAD_PERIOD: that day has not come yet'; end if;
  v_from := (v_day::timestamp at time zone 'Africa/Cairo');
  v_to   := ((v_day + 1)::timestamp at time zone 'Africa/Cairo');

  with
  -- ================================================================ NEW RECORDS
  ent as (
    -- HR
    select k.created_at as at, 'hr'::text as sys, 'created'::text as act, 'kpi_entries'::text as obj,
           coalesce(m.name_en, 'KPI') || ' × ' || rtrim(to_char(coalesce(k.quantity, 0), 'FM999999990.##'), '.') as title,
           (select coalesce(e.full_name_en, '') from employees e where e.id = k.employee_id) as detail,
           k.created_by as uid, null::text as who_name, null::boolean as late, true as logged
      from kpi_entries k left join kpi_metrics m on m.id = k.metric_id where k.created_at >= v_from and k.created_at < v_to
    union all
    select q.created_at, 'hr', 'created', 'leave_requests', coalesce(lt.name_en, 'Leave') || ' ' || q.start_date || case when q.end_date <> q.start_date then ' → ' || q.end_date else '' end,
           (select e.full_name_en from employees e where e.id = q.employee_id), (select e.user_id from employees e where e.id = q.employee_id), null, null, true
      from leave_requests q left join leave_types lt on lt.id = q.leave_type_id where q.created_at >= v_from and q.created_at < v_to
    union all
    select x.created_at, 'hr', 'created', 'attendance_exceptions', x.kind, (select e.full_name_en from employees e where e.id = x.employee_id), x.created_by, null, null, true
      from attendance_exceptions x where x.created_at >= v_from and x.created_at < v_to
    union all
    select e.created_at, 'hr', 'created', 'employees', coalesce(e.employee_code || ' ', '') || coalesce(e.full_name_en, ''), null, null, null, null, true
      from employees e where e.created_at >= v_from and e.created_at < v_to
    union all
    select h.created_at, 'hr', 'created', 'hr_tasks', h.title, (select e.full_name_en from employees e where e.id = h.employee_id), h.created_by, h.created_by_name, null, false
      from hr_tasks h where h.created_at >= v_from and h.created_at < v_to
    -- HV Finance
    union all
    select v.created_at, 'fin', 'created', 'fin_vouchers', coalesce(v.voucher_no, v.kind), trim(to_char(v.amount, 'FM999,999,999,990.00')) || ' ' || coalesce(v.currency, ''), v.created_by, null, null, true
      from fin_vouchers v where v.created_at >= v_from and v.created_at < v_to
    union all
    select i.created_at, 'fin', 'created', 'fin_invoices', coalesce(i.invoice_no, i.kind), trim(to_char(i.total, 'FM999,999,999,990.00')) || ' ' || coalesce(i.currency, ''), i.created_by, null, null, true
      from fin_invoices i where i.created_at >= v_from and i.created_at < v_to
    union all
    select b.created_at, 'fin', 'created', 'fin_bills', coalesce(b.bill_no, b.kind), trim(to_char(b.total, 'FM999,999,999,990.00')) || ' ' || coalesce(b.currency, ''), b.created_by, null, null, true
      from fin_bills b where b.created_at >= v_from and b.created_at < v_to
    union all
    select j.created_at, 'fin', 'created', 'fin_journals', coalesce(j.journal_no, j.kind), j.memo, j.created_by, null, null, true
      from fin_journals j where j.created_at >= v_from and j.created_at < v_to and j.kind in ('manual', 'opening', 'adjustment', 'closing')
    union all
    select f.created_at, 'fin', 'created', 'fin_tasks', f.title, (select e.full_name_en from employees e where e.id = f.employee_id), f.created_by, f.created_by_name, null, false
      from fin_tasks f where f.created_at >= v_from and f.created_at < v_to
    -- HV Ops
    union all
    select l.created_at, 'ops', 'created', case when coalesce(l.is_offline, false) then 'ops_offline' else 'ops_listings' end, btrim(coalesce(l.reference_code, '') || ' ' || coalesce(l.title, '')), l.location, l.entered_by, null, null, true
      from ops_listings l where l.created_at >= v_from and l.created_at < v_to
    union all
    select p.created_at, 'ops', 'created', 'ops_projects', btrim(coalesce(p.reference_code, '') || ' ' || coalesce(p.name, '')), null, p.entered_by, null, null, true
      from ops_projects p where p.created_at >= v_from and p.created_at < v_to
    union all
    select r.created_at, 'ops', 'created', 'ops_photo_requests', btrim(coalesce('PH-' || lpad(r.request_no::text, 4, '0'), '') || ' ' || coalesce(r.location, '')), r.owner_name, r.requested_by, null, null, true
      from ops_photo_requests r where r.created_at >= v_from and r.created_at < v_to
    union all
    select t.created_at, 'ops', 'created', 'ops_tasks', t.title, (select a.full_name_en from app_users a where a.id = t.assigned_to), t.created_by, null, null, true
      from ops_tasks t where t.created_at >= v_from and t.created_at < v_to
    -- Maintenance
    union all
    select t.created_at, 'maint', 'created', 'hv_tasks', 'T-' || lpad(t.id::text, 4, '0') || coalesce(' ' || tt.title, ''), (select p.name from hv_properties p where p.id = t.property_id), null,
           (select x ->> 'by' from jsonb_array_elements(case when jsonb_typeof(t.audit_trail) = 'array' then t.audit_trail else '[]'::jsonb end) x limit 1), null, true
      from hv_tasks t left join hv_task_types tt on tt.id = t.task_type_id where t.created_at >= v_from and t.created_at < v_to
    union all
    select i.created_at, 'maint', 'created', 'hv_invoices', btrim(coalesce(i.invoice_number, '') || ' ' || coalesce(i.client_name, '')),
           trim(to_char(coalesce(i.final_total, i.total_amount, 0), 'FM999,999,999,990.00')) || ' EGP', null, i.created_by, null, false
      from hv_invoices i where i.created_at >= v_from and i.created_at < v_to
    -- CRM (keeps no record of who did it)
    union all
    select b.created_at, 'crm', 'created', 'bookings', btrim(coalesce(pr.name, '') || ' · ' || coalesce(b.guest_name, '')),
           b.start_date || ' → ' || b.end_date || coalesce(' · ' || trim(to_char(b.amount, 'FM999,999,999,990.00')) || ' ' || coalesce(b.currency, ''), ''), null, null, null, false
      from bookings b left join properties pr on pr.id = b.property_id where b.created_at >= v_from and b.created_at < v_to
    union all
    select c.collected_at, 'crm', 'collected', 'collections', btrim(coalesce(pr.name, '') || ' · ' || coalesce(c.title, '')),
           trim(to_char(c.amount, 'FM999,999,999,990.00')) || ' ' || coalesce(nullif(c.currency, ''), 'EGP'), null, null, null, false
      from collections c left join properties pr on pr.id = c.property_id where c.status = 'collected' and c.collected_at >= v_from and c.collected_at < v_to
    union all
    select k.created_at, 'crm', 'created', 'crm_tasks', btrim(coalesce(pr.name, '') || ' · ' || coalesce(k.title, '')), k.task_type, null, null, null, false
      from tasks k left join properties pr on pr.id = k.property_id where k.created_at >= v_from and k.created_at < v_to
  ),
  -- ================================================================ TASKS DONE
  mt as (
    select t.*, 'T-' || lpad(t.id::text, 4, '0') || coalesce(' ' || tt.title, '') as code, coalesce(t.end_date, t.task_date) as e
      from hv_tasks t left join hv_task_types tt on tt.id = t.task_type_id
  ),
  done as (
    -- Maintenance: each assignee's submission, the task completed, the two reviews
    select (pg.value ->> 'submitted_at')::timestamptz as at, 'maint'::text as sys, 'submitted'::text as act, 'hv_tasks'::text as obj, mt.code as title, null::text as detail,
           null::uuid as uid, (select u.name from hv_users u where u.id::text = pg.key) as who_name,
           (mt.e is not null and ((pg.value ->> 'submitted_at')::timestamptz at time zone 'Africa/Cairo')::date > mt.e) as late, true as logged
      from mt cross join lateral jsonb_each(case when jsonb_typeof(mt.employee_progress) = 'object' then mt.employee_progress else '{}'::jsonb end) pg
     where jsonb_typeof(pg.value) = 'object' and coalesce(pg.value ->> 'submitted_at', '') ~ '^\d{4}-\d{2}-\d{2}'
       and (pg.value ->> 'submitted_at')::timestamptz >= v_from and (pg.value ->> 'submitted_at')::timestamptz < v_to
    union all
    select mt.actual_completion_date, 'maint', 'completed', 'hv_tasks', mt.code, null, null, mt.completed_by,
           (mt.e is not null and (mt.actual_completion_date at time zone 'Africa/Cairo')::date > mt.e), true
      from mt where mt.actual_completion_date >= v_from and mt.actual_completion_date < v_to
    union all
    select mt.admin_revised_at, 'maint', 'reviewed', 'hv_tasks', mt.code, null, null, mt.admin_revised_by, null, true
      from mt where mt.admin_revised_at >= v_from and mt.admin_revised_at < v_to
    union all
    select mt.supervisor_revised_at, 'maint', 'reviewed_senior', 'hv_tasks', mt.code, null, null, mt.supervisor_revised_by, null, true
      from mt where mt.supervisor_revised_at >= v_from and mt.supervisor_revised_at < v_to
    -- HV Ops
    union all
    select x.completed_at, 'ops', 'completed', 'ops_tasks', x.title, null, x.assigned_to, null, (x.due_at is not null and x.completed_at > x.due_at), true
      from ops_tasks x where x.completed_at >= v_from and x.completed_at < v_to
    union all
    select x.approved_at, 'ops', 'approved', 'ops_tasks', x.title, (select a.full_name_en from app_users a where a.id = x.assigned_to), x.approved_by, null, null, true
      from ops_tasks x where x.approved_at >= v_from and x.approved_at < v_to and x.approved_by is not null
    union all
    select l.date_published_claimed, 'ops', 'published', 'ops_listings', btrim(coalesce(l.reference_code, '') || ' ' || coalesce(l.title, '')), null, l.published_claimed_by, null, null, true
      from ops_listings l where l.date_published_claimed >= v_from and l.date_published_claimed < v_to
    union all
    select v.date_published_verified, 'ops', 'live', 'ops_listings', btrim(coalesce(v.reference_code, '') || ' ' || coalesce(v.title, '')),
           case when v.hours_to_publish is not null then round(v.hours_to_publish)::text || ' h' end, coalesce(v.published_claimed_by, v.assigned_to), null, not coalesce(v.is_on_time, false), false
      from ops_vw_listing_sla v where v.date_published_verified >= v_from and v.date_published_verified < v_to
    union all
    select r.shot_at, 'ops', 'shot', 'ops_photo_requests', btrim(coalesce('PH-' || lpad(r.request_no::text, 4, '0'), '') || ' ' || coalesce(r.location, '')), null, r.assigned_to, null, null, true
      from ops_photo_requests r where r.shot_at >= v_from and r.shot_at < v_to
    -- CRM, HR, Finance task lists
    union all
    select k.done_at, 'crm', 'completed', 'crm_tasks', btrim(coalesce(pr.name, '') || ' · ' || coalesce(k.title, '')), k.task_type, null, null,
           (k.end_date is not null and (k.done_at at time zone 'Africa/Cairo')::date > k.end_date), false
      from tasks k left join properties pr on pr.id = k.property_id where k.done_at >= v_from and k.done_at < v_to
    union all
    select h.completed_at, 'hr', 'completed', 'hr_tasks', h.title, h.done_note, coalesce(h.assigned_to, (select e.user_id from employees e where e.id = h.employee_id)), null,
           (h.due_date is not null and (h.completed_at at time zone 'Africa/Cairo')::date > h.due_date), false
      from hr_tasks h where h.completed_at >= v_from and h.completed_at < v_to
    union all
    select f.completed_at, 'fin', 'completed', 'fin_tasks', f.title, f.done_note, coalesce(f.assigned_to, (select e.user_id from employees e where e.id = f.employee_id)), null,
           (f.due_date is not null and (f.completed_at at time zone 'Africa/Cairo')::date > f.due_date), false
      from fin_tasks f where f.completed_at >= v_from and f.completed_at < v_to
  ),
  -- ================================================================ LOGGED ACTIONS
  lg as (
    -- HR + HV Finance audit log (line tables and log-in stamps left out)
    select a.created_at as at, case when a.entity like 'fin\_%' then 'fin' else 'hr' end::text as sys,
           case a.action when 'insert' then 'created' when 'update' then 'updated' when 'delete' then 'deleted' else a.action end::text as act,
           a.entity::text as obj,
           coalesce(
             case a.entity
               when 'kpi_entries' then (select e.full_name_en from employees e where e.id::text = coalesce(a.after_data, a.before_data) ->> 'employee_id')
                                       || coalesce(' · ' || (select m.name_en from kpi_metrics m where m.id::text = coalesce(a.after_data, a.before_data) ->> 'metric_id'), '')
               when 'leave_requests' then (select e.full_name_en from employees e where e.id::text = coalesce(a.after_data, a.before_data) ->> 'employee_id')
               when 'attendance_exceptions' then (select e.full_name_en from employees e where e.id::text = coalesce(a.after_data, a.before_data) ->> 'employee_id') || coalesce(' · ' || (coalesce(a.after_data, a.before_data) ->> 'kind'), '')
             end,
             coalesce(a.after_data, a.before_data) ->> 'voucher_no', coalesce(a.after_data, a.before_data) ->> 'invoice_no', coalesce(a.after_data, a.before_data) ->> 'bill_no',
             coalesce(a.after_data, a.before_data) ->> 'journal_no', coalesce(a.after_data, a.before_data) ->> 'title', coalesce(a.after_data, a.before_data) ->> 'title_en',
             coalesce(a.after_data, a.before_data) ->> 'full_name_en', coalesce(a.after_data, a.before_data) ->> 'name_en', coalesce(a.after_data, a.before_data) ->> 'username',
             coalesce(a.after_data, a.before_data) ->> 'code', a.entity_id)::text as title,
           coalesce(nullif(a.note, ''), case when a.action = 'update' then ch.keys end)::text as detail,
           a.actor_id as uid, a.actor_email::text as who_name, null::boolean as late, true as logged
      from audit_log a
      cross join lateral (select string_agg(n.key, ', ' order by n.key) as keys
                            from jsonb_each(case when jsonb_typeof(a.after_data) = 'object' then a.after_data else '{}'::jsonb end) n
                           where n.key not in ('updated_at', 'last_login_at') and (a.before_data -> n.key) is distinct from n.value) ch
     where a.created_at >= v_from and a.created_at < v_to
       and a.entity not in ('fin_journal_lines', 'fin_invoice_lines', 'fin_bill_lines', 'fin_owner_payout_items', 'fin_stock_move_lines', 'fin_stock_ledger',
                            'payroll_items', 'attendance_punches', 'fin_feed_log', 'fin_sequences', 'audit_log')
       and not (a.action = 'update' and ch.keys is null)            -- only log-in stamps / nothing really changed
    -- HV Ops change log: one line per record, person and minute
    union all
    select min(o.changed_at), 'ops', case o.action when 'insert' then 'created' when 'update' then 'updated' when 'delete' then 'deleted' else o.action end, o.table_name,
           coalesce(case o.table_name
             when 'ops_listings' then (select btrim(coalesce(l.reference_code, '') || ' ' || coalesce(l.title, '')) from ops_listings l where l.id = o.record_id)
             when 'ops_projects' then (select btrim(coalesce(p.reference_code, '') || ' ' || coalesce(p.name, '')) from ops_projects p where p.id = o.record_id)
             when 'ops_listing_channels' then (select coalesce(l.reference_code, '') || ' · ' || c.channel from ops_listing_channels c join ops_listings l on l.id = c.listing_id where c.id = o.record_id)
             when 'ops_photo_requests' then (select btrim(coalesce('PH-' || lpad(r.request_no::text, 4, '0'), '') || ' ' || coalesce(r.location, '')) from ops_photo_requests r where r.id = o.record_id)
             when 'ops_tasks' then (select x.title from ops_tasks x where x.id = o.record_id)
           end, o.record_id::text),
           string_agg(distinct o.field_name, ', ') filter (where o.field_name is not null), o.changed_by, null, null, true
      from ops_audit_log o
     where o.changed_at >= v_from and o.changed_at < v_to and not (o.table_name = 'ops_listing_channels' and o.action = 'insert')
     group by o.table_name, o.record_id, o.changed_by, o.action, date_trunc('minute', o.changed_at)
    -- Maintenance: the task log, comments, files
    union all
    select (x ->> 'timestamp')::timestamptz, 'maint', 'note', 'hv_tasks', mt.code, x ->> 'action', null, x ->> 'by', null, true
      from mt cross join lateral jsonb_array_elements(case when jsonb_typeof(mt.audit_trail) = 'array' then mt.audit_trail else '[]'::jsonb end) x
     where coalesce(x ->> 'timestamp', '') ~ '^\d{4}-\d{2}-\d{2}' and (x ->> 'timestamp')::timestamptz >= v_from and (x ->> 'timestamp')::timestamptz < v_to
    union all
    select c.created_at, 'maint', 'commented', 'hv_tasks', (select mt.code from mt where mt.id = c.task_id), left(c.comment_text, 200), null, c.author_name, null, true
      from hv_comments c where c.created_at >= v_from and c.created_at < v_to
    union all
    select f.created_at, 'maint', 'attached', 'hv_tasks', (select mt.code from mt where mt.id = f.task_id), f.file_name, null, f.uploaded_by_name, null, true
      from hv_attachments f where f.created_at >= v_from and f.created_at < v_to
    -- CRM activity log
    union all
    select y.at, 'crm', 'note', 'activity', (select pr.name from properties pr where pr.id = y.property_id), y.description, null, null, null, true
      from activity y where y.at >= v_from and y.at < v_to
  ),
  raw as (
    select 'entry'::text as list, e.* from ent e
    union all select 'done', d.* from done d
    union all select 'log', g.* from lg g
  ),
  -- who: a login (app_users) or a name (Maintenance keeps names) -> the employee
  ev as (
    select r.*, coalesce(eu.id, eh.id) as emp,
           coalesce(eu.full_name_en, eh.full_name_en, au.full_name_en, nullif(au.username, ''), r.who_name) as who_en,
           coalesce(nullif(eu.full_name_ar, ''), nullif(eh.full_name_ar, ''), nullif(au.full_name_ar, ''), eu.full_name_en, eh.full_name_en, au.full_name_en, r.who_name) as who_ar
      from raw r
      left join app_users au on au.id = r.uid
      left join lateral (select e.id, e.full_name_en, e.full_name_ar from employees e where r.uid is not null and e.user_id = r.uid order by (e.status = 'active') desc limit 1) eu on true
      left join lateral (select e.id, e.full_name_en, e.full_name_ar from hv_users u
                           join employees e on e.id = coalesce(u.employee_id, (select e3.id from employees e3 where e3.user_id = u.auth_user_id limit 1))
                          where r.uid is null and r.who_name is not null and u.name = r.who_name limit 1) eh on true
     where r.at is not null
  ),
  item as (
    select ev.*, jsonb_strip_nulls(jsonb_build_object('at', ev.at, 'sys', ev.sys, 'act', ev.act, 'obj', ev.obj, 'title', ev.title, 'detail', ev.detail,
                                                      'emp', ev.emp, 'who_en', ev.who_en, 'who_ar', ev.who_ar, 'late', ev.late)) as j
      from ev
  ),
  att as (select a.employee_id, a.late_days from public.kpi_attendance(v_day, v_day) a),
  ppl as (
    select e.id, e.employee_code, e.full_name_en, e.full_name_ar, coalesce(e.department_id::text, 'none') as dept_key, coalesce(e.attendance_exempt, false) as exempt,
           (select min(p.punch_time) from attendance_punches p where p.employee_id = e.id and p.punch_time >= v_from and p.punch_time < v_to and p.direction not in ('out', 'break_out', 'break_in', 'ot_in', 'ot_out')) as first_in,
           (select max(p.punch_time) from attendance_punches p where p.employee_id = e.id and p.punch_time >= v_from and p.punch_time < v_to and p.direction = 'out') as last_out,
           coalesce((select att.late_days > 0 from att where att.employee_id = e.id), false) as late,
           exists (select 1 from leave_requests q where q.employee_id = e.id and q.status = 'approved' and v_day between q.start_date and q.end_date) as on_leave,
           (select count(*) from item i where i.emp = e.id and i.list = 'entry') as entries,
           (select count(*) from item i where i.emp = e.id and i.list = 'done') as done,
           (select count(*) from item i where i.emp = e.id and i.list = 'log') as actions
      from employees e
     where e.status = 'active' or exists (select 1 from item i where i.emp = e.id)
  )
  select jsonb_build_object(
    'day', v_day, 'today', v_today, 'at', now(),
    'entries',  coalesce((select jsonb_agg(z.j order by z.at) from (select i.j, i.at from item i where i.list = 'entry' order by i.at limit v_max) z), '[]'::jsonb),
    'done',     coalesce((select jsonb_agg(z.j order by z.at) from (select i.j, i.at from item i where i.list = 'done' order by i.at limit v_max) z), '[]'::jsonb),
    'timeline', coalesce((select jsonb_agg(z.j order by z.at) from (select i.j, i.at from item i where i.list = 'log' or not i.logged order by i.at limit v_max) z), '[]'::jsonb),
    'truncated', (select count(*) from item i where i.list = 'log' or not i.logged) > v_max,
    'summary', coalesce((select jsonb_object_agg(s.sys, jsonb_build_object('entries', s.entries, 'done', s.done, 'actions', s.actions))
                           from (select i.sys, count(*) filter (where i.list = 'entry') as entries, count(*) filter (where i.list = 'done') as done,
                                        count(*) filter (where i.list = 'log' or not i.logged) as actions from item i group by i.sys) s), '{}'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id', p.id, 'code', p.employee_code, 'name_en', p.full_name_en, 'name_ar', p.full_name_ar, 'dept_key', p.dept_key,
                                                                              'exempt', p.exempt, 'first_in', p.first_in, 'last_out', p.last_out, 'late', p.late, 'on_leave', p.on_leave,
                                                                              'entries', p.entries, 'done', p.done, 'actions', p.actions))
                                         order by (p.entries + p.done + p.actions) desc, p.full_name_en) from ppl p), '[]'::jsonb),
    'departments', coalesce((select jsonb_agg(jsonb_build_object('key', d.id::text, 'name_en', d.name_en, 'name_ar', d.name_ar) order by d.name_en) from departments d where d.is_active), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$fn$;

-- the call the app makes: CEO-only
create or replace function public.mgmt_day_report(p_day date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
begin
  perform public.mgmt_require();
  return public.mgmt_day_data(p_day);
end;
$fn$;

revoke all on function public.mgmt_day_data(date) from public, anon, authenticated;
revoke all on function public.mgmt_day_report(date) from public, anon;
grant execute on function public.mgmt_day_report(date) to authenticated;

notify pgrst, 'reload schema';
