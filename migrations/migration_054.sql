-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_054.sql
-- TASK LISTS IN HR AND HV FINANCE (Daniel, 2026-10-19). HV Management's
-- "Give a task" could only send to Maintenance, HV Ops and the CRM, so
-- sales, accounts and HR people could not get a task. Daniel: "you choose
-- first the system to give the task in ... it appears in the system they
-- chose". So two more systems get their own task list:
--   * HR (hr_tasks): any employee with an HR login (sales, accounts, HR,
--     everyone). They see it in HR -> Tasks.
--   * HV Finance (fin_tasks): the logins with the HV Finance tick. They
--     see it in HV Finance -> My tasks.
-- The person taps Start, then Done. DONE IS FINAL (Daniel: no approval
-- step). In HR the CEO and HR see every task, and so do Finance admins
-- and CEOs in Finance; they and the person who gave a task may cancel it.
-- Like the other systems: a notification through hv_notify, 🔔 lines
-- ("Your open tasks", "Your late tasks") in hv_alerts_hr / hv_alerts_fin,
-- and in HV Management the given list, the "Tasks you gave that are late"
-- alert and the Team numbers (tasks done / late / open / overdue) count
-- them. Writes only go through the functions below (RLS: read only).
-- ADDITIVE ONLY. Safe to re-run. Run after 053.
-- =====================================================================

-- ---------------------------------------------------------------- the two task lists
create table if not exists public.hr_tasks (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  description     text,
  employee_id     uuid not null,                      -- employees.id: the person who does it
  assigned_to     uuid,                               -- app_users.id: that person's login when the task was given
  priority        text not null default 'normal',
  due_date        date,
  status          text not null default 'todo',
  source          text not null default 'hr',         -- 'mgmt' = given from HV Management
  created_by      uuid,
  created_by_name text,
  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  completed_at    timestamptz,
  done_note       text,
  cancelled_by    uuid,
  cancelled_at    timestamptz,
  updated_at      timestamptz not null default now(),
  constraint hr_tasks_title_chk    check (btrim(title) <> ''),
  constraint hr_tasks_priority_chk check (priority in ('low', 'normal', 'high', 'urgent')),
  constraint hr_tasks_status_chk   check (status in ('todo', 'doing', 'done', 'cancelled')),
  constraint hr_tasks_source_chk   check (source in ('hr', 'mgmt'))
);
create index if not exists hr_tasks_assigned on public.hr_tasks (assigned_to, status);
create index if not exists hr_tasks_employee on public.hr_tasks (employee_id, status);
create index if not exists hr_tasks_created_by on public.hr_tasks (created_by, created_at desc);

create table if not exists public.fin_tasks (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  description     text,
  task_type       text not null default 'other',      -- collect / pay / invoice / entries / reconcile / tax / report / other
  assigned_to     uuid not null,                      -- app_users.id with the HV Finance tick
  employee_id     uuid,                               -- that login's employee (for the Team numbers)
  amount          numeric(14, 2),
  currency        text,
  priority        text not null default 'normal',
  due_date        date,
  status          text not null default 'todo',
  source          text not null default 'fin',        -- 'mgmt' = given from HV Management
  created_by      uuid,
  created_by_name text,
  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  completed_at    timestamptz,
  done_note       text,
  cancelled_by    uuid,
  cancelled_at    timestamptz,
  updated_at      timestamptz not null default now(),
  constraint fin_tasks_title_chk    check (btrim(title) <> ''),
  constraint fin_tasks_type_chk     check (task_type in ('collect', 'pay', 'invoice', 'entries', 'reconcile', 'tax', 'report', 'other')),
  constraint fin_tasks_priority_chk check (priority in ('low', 'normal', 'high', 'urgent')),
  constraint fin_tasks_status_chk   check (status in ('todo', 'doing', 'done', 'cancelled')),
  constraint fin_tasks_source_chk   check (source in ('fin', 'mgmt')),
  constraint fin_tasks_amount_chk   check (amount is null or amount > 0)
);
create index if not exists fin_tasks_assigned on public.fin_tasks (assigned_to, status);
create index if not exists fin_tasks_created_by on public.fin_tasks (created_by, created_at desc);

-- read: my own tasks; CEO / HR see all of HR's, Finance admins and CEOs all of Finance's. No write policies.
alter table public.hr_tasks enable row level security;
alter table public.fin_tasks enable row level security;
do $$
begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'hr_tasks' and policyname = 'hr_tasks_select') then
    create policy hr_tasks_select on public.hr_tasks for select to authenticated
      using (assigned_to = auth.uid() or employee_id = public.my_employee_id() or public.has_role('ceo', 'hr'));
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'fin_tasks' and policyname = 'fin_tasks_select') then
    create policy fin_tasks_select on public.fin_tasks for select to authenticated
      using (assigned_to = auth.uid() or public.fin_is_admin() or public.has_role('ceo'));
  end if;
end $$;
revoke all on table public.hr_tasks, public.fin_tasks from anon;
revoke insert, update, delete, truncate, references, trigger on table public.hr_tasks, public.fin_tasks from authenticated;
grant select on table public.hr_tasks, public.fin_tasks to authenticated;

-- ---------------------------------------------------------------- notifications (the shared outbox, like HV Ops' tasks)
-- new task -> the person; done -> whoever gave it. A message must never block the task itself.
create or replace function public.hr_tasks_notify()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  v_who text;
begin
  begin
    if tg_op = 'INSERT' and new.status in ('todo', 'doing') then
      perform public.hv_notify(new.assigned_to, 'hr', 'task', new.id::text, 'Task: ' || new.title,
        coalesce('Due ' || to_char(new.due_date, 'DD Mon'), 'No due date') || case when new.priority in ('high', 'urgent') then ' · ' || new.priority else '' end
          || coalesce(' · from ' || new.created_by_name, ''),
        'https://home-vacation-hr.pages.dev/#go/tasks');
    elsif tg_op = 'UPDATE' and new.status = 'done' and old.status is distinct from 'done' and new.created_by is not null then
      select coalesce(nullif(e.full_name_en, ''), e.full_name_ar) into v_who from employees e where e.id = new.employee_id;
      perform public.hv_notify(new.created_by, case when new.source = 'mgmt' then 'mgmt' else 'hr' end, 'task_done', new.id::text, 'Done: ' || new.title,
        coalesce(v_who, '') || coalesce(' · ' || new.done_note, ''),
        case when new.source = 'mgmt' then 'https://home-vacation-management.pages.dev/#tasks' else 'https://home-vacation-hr.pages.dev/#go/tasks' end);
    end if;
  exception when others then null;
  end;
  return new;
end;
$fn$;

create or replace function public.fin_tasks_notify()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  v_who text;
begin
  begin
    if tg_op = 'INSERT' and new.status in ('todo', 'doing') then
      perform public.hv_notify(new.assigned_to, 'fin', 'task', new.id::text, 'Task: ' || new.title,
        coalesce('Due ' || to_char(new.due_date, 'DD Mon'), 'No due date') || case when new.priority in ('high', 'urgent') then ' · ' || new.priority else '' end
          || coalesce(' · ' || new.amount || ' ' || coalesce(new.currency, ''), '') || coalesce(' · from ' || new.created_by_name, ''),
        'https://home-vacation-finance.pages.dev/#go/tasks');
    elsif tg_op = 'UPDATE' and new.status = 'done' and old.status is distinct from 'done' and new.created_by is not null then
      select coalesce(nullif(a.full_name_en, ''), a.username) into v_who from app_users a where a.id = new.assigned_to;
      perform public.hv_notify(new.created_by, case when new.source = 'mgmt' then 'mgmt' else 'fin' end, 'task_done', new.id::text, 'Done: ' || new.title,
        coalesce(v_who, '') || coalesce(' · ' || new.done_note, ''),
        case when new.source = 'mgmt' then 'https://home-vacation-management.pages.dev/#tasks' else 'https://home-vacation-finance.pages.dev/#go/tasks' end);
    end if;
  exception when others then null;
  end;
  return new;
end;
$fn$;

do $$
begin
  if not exists (select 1 from pg_trigger where tgname = 'trg_hr_tasks_notify' and tgrelid = 'public.hr_tasks'::regclass) then
    create trigger trg_hr_tasks_notify after insert or update of status on public.hr_tasks for each row execute function public.hr_tasks_notify();
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'trg_fin_tasks_notify' and tgrelid = 'public.fin_tasks'::regclass) then
    create trigger trg_fin_tasks_notify after insert or update of status on public.fin_tasks for each row execute function public.fin_tasks_notify();
  end if;
end $$;

-- ---------------------------------------------------------------- Start / Done / Cancel (the only way a task changes)
-- doing, done: only the person the task is for. Done is final. cancelled: CEO / HR (HR), Finance admin / CEO (Finance),
-- or whoever gave the task. Returns the saved row so the app updates its list at once.
create or replace function public.hr_task_set_status(p_id uuid, p_status text, p_note text default null)
returns public.hr_tasks language plpgsql volatile security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_t public.hr_tasks;
  v_mine boolean;
  v_boss boolean;
begin
  if v_uid is null then raise exception 'NOT_SIGNED_IN' using errcode = '42501'; end if;
  select * into v_t from hr_tasks where id = p_id for update;
  if v_t.id is null then raise exception 'TASK_NOT_FOUND'; end if;
  v_mine := v_t.assigned_to = v_uid or exists (select 1 from employees e where e.id = v_t.employee_id and e.user_id = v_uid);
  v_boss := public.has_role('ceo', 'hr');
  if not (coalesce(v_mine, false) or v_boss or v_t.created_by = v_uid) then raise exception 'NOT_YOUR_TASK' using errcode = '42501'; end if;
  if v_t.status in ('done', 'cancelled') then raise exception 'TASK_CLOSED'; end if;
  if p_status = 'doing' and v_mine then
    update hr_tasks set status = 'doing', started_at = coalesce(started_at, now()), updated_at = now() where id = p_id returning * into v_t;
  elsif p_status = 'done' and v_mine then
    update hr_tasks set status = 'done', started_at = coalesce(started_at, now()), completed_at = now(),
                        done_note = nullif(btrim(coalesce(p_note, '')), ''), updated_at = now()
     where id = p_id returning * into v_t;
  elsif p_status = 'cancelled' and (v_boss or v_t.created_by = v_uid) then
    update hr_tasks set status = 'cancelled', cancelled_by = v_uid, cancelled_at = now(), updated_at = now() where id = p_id returning * into v_t;
  else
    raise exception 'BAD_STATUS';
  end if;
  return v_t;
end;
$fn$;

create or replace function public.fin_task_set_status(p_id uuid, p_status text, p_note text default null)
returns public.fin_tasks language plpgsql volatile security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_t public.fin_tasks;
  v_mine boolean;
  v_boss boolean;
begin
  if v_uid is null then raise exception 'NOT_SIGNED_IN' using errcode = '42501'; end if;
  select * into v_t from fin_tasks where id = p_id for update;
  if v_t.id is null then raise exception 'TASK_NOT_FOUND'; end if;
  v_mine := v_t.assigned_to = v_uid;
  v_boss := public.fin_is_admin() or public.has_role('ceo');
  if not (v_mine or v_boss or v_t.created_by = v_uid) then raise exception 'NOT_YOUR_TASK' using errcode = '42501'; end if;
  if v_t.status in ('done', 'cancelled') then raise exception 'TASK_CLOSED'; end if;
  if p_status = 'doing' and v_mine then
    update fin_tasks set status = 'doing', started_at = coalesce(started_at, now()), updated_at = now() where id = p_id returning * into v_t;
  elsif p_status = 'done' and v_mine then
    update fin_tasks set status = 'done', started_at = coalesce(started_at, now()), completed_at = now(),
                         done_note = nullif(btrim(coalesce(p_note, '')), ''), updated_at = now()
     where id = p_id returning * into v_t;
  elsif p_status = 'cancelled' and (v_boss or v_t.created_by = v_uid) then
    update fin_tasks set status = 'cancelled', cancelled_by = v_uid, cancelled_at = now(), updated_at = now() where id = p_id returning * into v_t;
  else
    raise exception 'BAD_STATUS';
  end if;
  return v_t;
end;
$fn$;

-- ---------------------------------------------------------------- 🔔 HR: the live hv_alerts_hr (migration_050) + my tasks first
create or replace function public.hv_alerts_hr(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_role text;
  v_emp  uuid;
  v_boss boolean;          -- ceo / hr: sees everything
  v_items jsonb := '[]'::jsonb;
  v_n int;
  v_late int;
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_weekend jsonb;
  v_lead boolean;
  v_last timestamptz;
begin
  select a.role into v_role from app_users a where a.id = p_uid and a.is_active and coalesce(a.access_hr, false);
  if v_role is null then return null; end if;
  select e.id into v_emp from employees e where e.user_id = p_uid and e.status = 'active' limit 1;
  v_boss := v_role in ('ceo','hr');

  -- tasks given to me (migration_054): the late ones, then the other open ones
  select count(*) filter (where t.due_date is null or t.due_date >= v_today), count(*) filter (where t.due_date < v_today)
    into v_n, v_late
    from hr_tasks t
   where t.status in ('todo', 'doing') and (t.assigned_to = p_uid or (v_emp is not null and t.employee_id = v_emp));
  if v_late > 0 then v_items := v_items || jsonb_build_object('en', 'Your late tasks', 'ar', 'مهامك المتأخرة', 'n', v_late, 'page', 'tasks'); end if;
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Your open tasks', 'ar', 'مهامك المفتوحة', 'n', v_n, 'page', 'tasks'); end if;

  -- leave requests waiting for me (manager: my team's new ones; HR/CEO: new + manager-approved)
  select count(*) into v_n from leave_requests r join employees e on e.id = r.employee_id
   where (v_boss and r.status in ('pending','manager_approved'))
      or (not v_boss and v_emp is not null and r.status = 'pending' and e.manager_id = v_emp and e.id <> v_emp);
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Leave requests to approve', 'ar', 'طلبات إجازة بانتظار الاعتماد', 'n', v_n, 'page', 'leave', 'action', 'leave-tab-approvals'); end if;

  -- late / break / early-leave notes waiting for a decision
  select count(*) into v_n from attendance_exceptions x join employees e on e.id = x.employee_id
   where x.status = 'pending' and x.kind <> 'missing_punch'
     and (v_boss or (v_emp is not null and e.manager_id = v_emp and e.id <> v_emp));
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Attendance notes to decide', 'ar', 'أذونات حضور بانتظار القرار', 'n', v_n, 'page', 'attendance', 'action', 'att-tab-exceptions'); end if;

  -- days that ended without a check-out and still need a decision (last 31 days)
  select coalesce((select value->'weekend_days' from app_settings where key = 'work_week'), '[5,6]'::jsonb) into v_weekend;
  select count(*) into v_n from (
    select p.employee_id, (p.punch_time at time zone 'Africa/Cairo')::date d
      from attendance_punches p join employees e on e.id = p.employee_id
     where p.employee_id is not null and e.status = 'active' and not coalesce(e.attendance_exempt, false)
       and p.punch_time >= now() - interval '31 days'
       and (v_boss or (v_emp is not null and e.manager_id = v_emp and e.id <> v_emp))
     group by 1, 2
    having bool_or(p.direction = 'in') and not bool_or(p.direction = 'out')
       and (p.punch_time at time zone 'Africa/Cairo')::date < (now() at time zone 'Africa/Cairo')::date
  ) d
  join employees e on e.id = d.employee_id
  where not (coalesce(e.weekend_days, v_weekend) @> to_jsonb(extract(dow from d.d)::int))
    and not exists (select 1 from attendance_exceptions x where x.employee_id = d.employee_id and x.exc_date = d.d and x.kind = 'missing_punch' and x.status in ('approved','rejected'));
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Missing check-outs to decide', 'ar', 'بصمات انصراف ناقصة تحتاج قراراً', 'n', v_n, 'page', 'attendance', 'action', 'att-tab-review'); end if;

  -- KPI results waiting for approval
  select count(*) into v_n from kpi_entries k join employees e on e.id = k.employee_id
   where k.status = 'pending' and (v_boss or (v_emp is not null and e.manager_id = v_emp and e.id <> v_emp));
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'KPI results to approve', 'ar', 'نتائج مؤشرات بانتظار الاعتماد', 'n', v_n, 'page', 'kpi', 'action', 'kpi-tab-approvals'); end if;

  -- make-up day claims
  select count(*) into v_n from leave_makeups m join employees e on e.id = m.employee_id
   where m.status = 'pending' and (v_boss or (v_emp is not null and e.manager_id = v_emp and e.id <> v_emp));
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Make-up day claims', 'ar', 'طلبات أيام تعويض', 'n', v_n, 'page', 'leave', 'action', 'leave-tab-makeup'); end if;

  if v_boss then
    select count(*) into v_n from app_users a where a.approval_status = 'pending';
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Sign-ups to approve', 'ar', 'حسابات جديدة بانتظار الموافقة', 'n', v_n, 'page', 'users'); end if;
    select count(*) into v_n from password_reset_requests r where r.status = 'pending';
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Password reset requests', 'ar', 'طلبات إعادة تعيين كلمة المرور', 'n', v_n, 'page', 'users'); end if;
  end if;

  -- weekly Engaz upload overdue (sales team leaders, and CEO/HR)
  v_lead := v_emp is not null and v_role <> 'staff' and exists (
    select 1 from employees e left join departments d on d.id = e.department_id
     where e.id = v_emp
       and ((d.name_en || ' ' || coalesce(d.name_ar, '')) ~* 'sales|مبيعات' or coalesce(e.job_title_en, '') ~* 'sales' or coalesce(e.job_title_ar, '') ~ 'مبيعات')
       and (exists (select 1 from employees r where r.manager_id = e.id and r.status = 'active')
            or coalesce(e.job_title_en, '') ~* 'leader|manager|head|supervisor|director' or coalesce(e.job_title_ar, '') ~ 'مدير|قائد|رئيس|مشرف'));
  if v_lead or v_boss then
    select max(created_at) into v_last from engaz_imports;
    if v_last is null or v_last < now() - interval '7 days' then
      v_items := v_items || jsonb_build_object('en', 'Weekly Engaz upload overdue', 'ar', 'تحديث إنجاز الأسبوعي متأخر', 'n', 1, 'page', 'kpi', 'action', 'kpi-tab-engaz');
    end if;
  end if;

  return jsonb_build_object('n', (select coalesce(sum((x->>'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$fn$;

-- ---------------------------------------------------------------- 🔔 Finance: the live hv_alerts_fin (migration_050) + my tasks
-- (a viewer gets only their own tasks; before this a viewer always got 0)
create or replace function public.hv_alerts_fin(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_role text;
  v_items jsonb := '[]'::jsonb;
  v_n int;
  v_late int;
  v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  select public.fin_role_of(a) into v_role from app_users a where a.id = p_uid and a.is_active and coalesce(a.access_fin, false);
  if v_role is null then return null; end if;

  -- tasks given to me (migration_054)
  select count(*) filter (where t.due_date is null or t.due_date >= v_today), count(*) filter (where t.due_date < v_today)
    into v_n, v_late
    from fin_tasks t where t.assigned_to = p_uid and t.status in ('todo', 'doing');
  if v_late > 0 then v_items := v_items || jsonb_build_object('en', 'Your late tasks', 'ar', 'مهامك المتأخرة', 'n', v_late, 'page', 'tasks'); end if;
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Your open tasks', 'ar', 'مهامك المفتوحة', 'n', v_n, 'page', 'tasks'); end if;

  if v_role <> 'viewer' then
    select (select count(*) from fin_journals j where j.status = 'draft' and not exists (select 1 from fin_vouchers v where v.journal_id = j.id))
         + (select count(*) from fin_vouchers v where v.status = 'draft')
         + (select count(*) from fin_invoices i where i.status = 'draft' and i.source_table is not null)
         + (select count(*) from fin_bills b where b.status = 'draft' and b.source_table is not null) into v_n;
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Drafts to post', 'ar', 'مسودات بانتظار الترحيل', 'n', v_n, 'page', 'journals'); end if;
    select count(*) into v_n from fin_invoices i where i.kind = 'invoice' and i.status in ('issued','partial') and i.due_date < v_today;
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Overdue invoices', 'ar', 'فواتير متأخرة', 'n', v_n, 'page', 'invoices'); end if;
    select count(*) into v_n from fin_bills b where b.kind = 'bill' and b.status in ('approved','partial') and b.due_date < v_today;
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Overdue bills', 'ar', 'مستحقات موردين متأخرة', 'n', v_n, 'page', 'bills'); end if;
    select count(*) into v_n from fin_tax_returns r where r.status = 'filed' and coalesce(r.amount_due, 0) > 0;
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Filed tax returns not yet paid', 'ar', 'إقرارات ضريبية لم تُسدد', 'n', v_n, 'page', 'tax'); end if;
    if p_uid = auth.uid() then
      begin
        select count(*) into v_n from public.fin_rent_reminders() r where r.days_left <= 0;
        if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Rent payments due', 'ar', 'إيجارات مستحقة', 'n', v_n, 'page', 'rentals'); end if;
      exception when others then null;
      end;
    end if;
  end if;
  return jsonb_build_object('n', (select coalesce(sum((x->>'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$fn$;

-- ---------------------------------------------------------------- HV Management: GIVE A TASK — the lists the form needs (053 + hr + fin)
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
      'properties', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name), '[]'::jsonb) from properties p)),
    -- HR: every active employee with a working HR login, with the department to pick a whole team
    'hr', jsonb_build_object(
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', coalesce(nullif(e.full_name_en, ''), a.username), 'name_ar', e.full_name_ar, 'code', e.employee_code,
                                                              'dept_key', coalesce(e.department_id::text, 'none'), 'job_en', e.job_title_en, 'job_ar', e.job_title_ar) order by e.full_name_en), '[]'::jsonb)
                   from employees e join app_users a on a.id = e.user_id
                  where e.status = 'active' and a.is_active and coalesce(a.access_hr, true) and coalesce(a.approval_status, 'approved') = 'approved'),
      'departments', (select coalesce(jsonb_agg(jsonb_build_object('key', x.key, 'name_en', x.name_en, 'name_ar', x.name_ar) order by x.ord, x.name_en), '[]'::jsonb)
                        from (select d.id::text as key, d.name_en, d.name_ar, 0 as ord from departments d where d.is_active
                              union all select 'none', 'No department', 'بدون قسم', 1) x)),
    -- HV Finance: the logins with the HV Finance tick
    'fin', jsonb_build_object(
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', coalesce(nullif(a.full_name_en, ''), a.username), 'name_ar', a.full_name_ar, 'role', public.fin_role_of(a)) order by a.full_name_en), '[]'::jsonb)
                   from app_users a where a.is_active and coalesce(a.access_fin, false)),
      'currencies', coalesce((select jsonb_agg(c.code order by c.sort, c.code) from fin_currencies c where coalesce(c.is_active, true)), '["EGP"]'::jsonb)));
end;
$fn$;

-- ---------------------------------------------------------------- HV Management: GIVE A TASK — write it into the chosen system (053 + hr + fin)
-- p_task (maint): { task_type_id, location_type, property_id?, source_store?, destination_store?, people: [hv_users ids],
--                   start_date, end_date?, notes?, subtasks?: [text] }
-- p_task (ops):   { title, description?, task_type?, assigned_to (app_users id), priority?, due_at? }
-- p_task (crm):   { property_id, title, task_type?, start_date, end_date?, priority?, notes? }
-- p_task (hr):    { title, description?, people: [employees ids], priority?, due_date? }            one task per person
-- p_task (fin):   { title, description?, task_type?, people: [app_users ids], amount?, currency?, priority?, due_date? }
create or replace function public.mgmt_give_task(p_system text, p_task jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_by text; v_id text; v_title text; v_names text; v_due date;
  v_type hv_task_types%rowtype; v_loc text; v_prop bigint; v_src bigint; v_dst bigint; v_people bigint[]; v_start date; v_end date; v_subs jsonb;
  v_assignee uuid; v_prio text; v_due_at timestamptz; v_cprop uuid; v_ctype text;
  v_ids uuid[]; v_new text[]; v_desc text; v_ftype text; v_amount numeric; v_cur text; v_me text;
begin
  perform public.mgmt_require();
  select coalesce((select u.name from hv_users u where u.auth_user_id = v_uid limit 1), nullif(a.full_name_ar, ''), a.full_name_en, a.username),
         coalesce(nullif(a.full_name_en, ''), a.username)
    into v_by, v_me from app_users a where a.id = v_uid;

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

  elsif p_system in ('hr', 'fin') then
    v_title := btrim(coalesce(p_task ->> 'title', ''));
    if v_title = '' then raise exception 'TITLE_REQUIRED'; end if;
    v_desc := nullif(btrim(coalesce(p_task ->> 'description', '')), '');
    v_prio := coalesce(nullif(p_task ->> 'priority', ''), 'normal');
    if v_prio not in ('low', 'normal', 'high', 'urgent') then raise exception 'BAD_PRIORITY'; end if;
    v_due := nullif(p_task ->> 'due_date', '')::date;
    if v_due < v_today then raise exception 'DUE_IN_PAST'; end if;
    select array_agg(distinct (x #>> '{}')::uuid) into v_ids
      from jsonb_array_elements(case when jsonb_typeof(p_task -> 'people') = 'array' then p_task -> 'people' else '[]'::jsonb end) x;
    if v_ids is null then raise exception 'ASSIGNEE_REQUIRED'; end if;

    if p_system = 'hr' then
      -- only active employees whose HR login works can see the task
      if exists (select 1 from unnest(v_ids) i where not exists (
                   select 1 from employees e join app_users a on a.id = e.user_id
                    where e.id = i and e.status = 'active' and a.is_active and coalesce(a.access_hr, true) and coalesce(a.approval_status, 'approved') = 'approved')) then
        raise exception 'ASSIGNEE_REQUIRED';
      end if;
      with ins as (
        insert into hr_tasks (title, description, employee_id, assigned_to, priority, due_date, source, created_by, created_by_name)
        select v_title, v_desc, e.id, e.user_id, v_prio, v_due, 'mgmt', v_uid, v_me from employees e where e.id = any (v_ids)
        returning id, employee_id)
      select array_agg(ins.id::text order by e.full_name_en), string_agg(coalesce(nullif(e.full_name_en, ''), e.full_name_ar), ', ' order by e.full_name_en)
        into v_new, v_names from ins join employees e on e.id = ins.employee_id;
    else
      v_ftype := coalesce(nullif(p_task ->> 'task_type', ''), 'other');
      if v_ftype not in ('collect', 'pay', 'invoice', 'entries', 'reconcile', 'tax', 'report', 'other') then raise exception 'BAD_TASK_TYPE'; end if;
      v_amount := nullif(p_task ->> 'amount', '')::numeric;
      if v_amount is not null and v_amount <= 0 then raise exception 'BAD_AMOUNT'; end if;
      v_cur := case when v_amount is null then null else coalesce(nullif(p_task ->> 'currency', ''), 'EGP') end;
      if v_cur is not null and not exists (select 1 from fin_currencies c where c.code = v_cur) then raise exception 'BAD_CURRENCY'; end if;
      if exists (select 1 from unnest(v_ids) i where not exists (select 1 from app_users a where a.id = i and a.is_active and coalesce(a.access_fin, false))) then
        raise exception 'ASSIGNEE_REQUIRED';
      end if;
      with ins as (
        insert into fin_tasks (title, description, task_type, assigned_to, employee_id, amount, currency, priority, due_date, source, created_by, created_by_name)
        select v_title, v_desc, v_ftype, a.id, (select e.id from employees e where e.user_id = a.id and e.status = 'active' limit 1),
               round(v_amount, 2), v_cur, v_prio, v_due, 'mgmt', v_uid, v_me
          from app_users a where a.id = any (v_ids)
        returning id, assigned_to)
      select array_agg(ins.id::text order by a.full_name_en), string_agg(coalesce(nullif(a.full_name_en, ''), a.username), ', ' order by a.full_name_en)
        into v_new, v_names from ins join app_users a on a.id = ins.assigned_to;
    end if;
    v_id := v_new[1];
    -- not written to mgmt_task_log (its system check is maint / ops / crm): the task row itself remembers it (source 'mgmt')
    return jsonb_build_object('system', p_system, 'id', v_id, 'ids', to_jsonb(v_new), 'title', v_title, 'assignees', v_names);

  else
    raise exception 'UNKNOWN_SYSTEM';
  end if;

  insert into mgmt_task_log (system, target_id, title, assignees, due, created_by) values (p_system, v_id, v_title, v_names, v_due, v_uid);
  return jsonb_build_object('system', p_system, 'id', v_id, 'title', v_title, 'assignees', v_names);
end;
$fn$;

-- ---------------------------------------------------------------- HV Management: the tasks given, with their live status (053 + hr + fin)
create or replace function public.mgmt_given_tasks(p_limit int default 40)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  perform public.mgmt_require();
  return (
    select coalesce(jsonb_agg(s.r order by s.at desc), '[]'::jsonb) from (
      select u.r, u.at from (
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
          end) as r, g.created_at as at
          from mgmt_task_log g left join app_users a on a.id = g.created_by
        union all
        select jsonb_build_object('id', t.id, 'system', 'hr', 'target_id', t.id::text, 'title', t.title,
                                  'assignees', coalesce(nullif(e.full_name_en, ''), e.full_name_ar), 'due', t.due_date,
                                  'created_at', t.created_at, 'by', coalesce(nullif(a.full_name_en, ''), a.username, t.created_by_name),
                                  'done_at', t.completed_at, 'note', t.done_note,
                                  'status', case when t.status in ('done', 'cancelled') then t.status when t.due_date < v_today then 'late'
                                                 when t.status = 'doing' then 'in_progress' else 'open' end), t.created_at
          from hr_tasks t left join employees e on e.id = t.employee_id left join app_users a on a.id = t.created_by
         where t.source = 'mgmt'
        union all
        select jsonb_build_object('id', t.id, 'system', 'fin', 'target_id', t.id::text, 'title', t.title,
                                  'assignees', coalesce(nullif(p.full_name_en, ''), p.username), 'due', t.due_date,
                                  'created_at', t.created_at, 'by', coalesce(nullif(a.full_name_en, ''), a.username, t.created_by_name),
                                  'done_at', t.completed_at, 'note', t.done_note,
                                  'status', case when t.status in ('done', 'cancelled') then t.status when t.due_date < v_today then 'late'
                                                 when t.status = 'doing' then 'in_progress' else 'open' end), t.created_at
          from fin_tasks t left join app_users p on p.id = t.assigned_to left join app_users a on a.id = t.created_by
         where t.source = 'mgmt'
      ) u
      order by u.at desc
      limit least(greatest(coalesce(p_limit, 40), 1), 200)) s);
end;
$fn$;

-- ---------------------------------------------------------------- HV Management 🔔 (053): "Tasks you gave that are late" now counts HR and Finance too
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
    select (select count(*) from mgmt_task_log g
             where g.created_by = p_uid and g.due < v_today
               and ((g.system = 'maint' and exists (select 1 from hv_tasks t where t.id::text = g.target_id and t.actual_completion_date is null and t.admin_revised_at is null and t.supervisor_revised_at is null and t.submitted_at is null))
                 or (g.system = 'ops' and exists (select 1 from ops_tasks x where x.id::text = g.target_id and x.status::text not in ('done', 'cancelled', 'review')))
                 or (g.system = 'crm' and exists (select 1 from tasks k where k.id::text = g.target_id and k.status <> 'done'))))
         + (select count(*) from hr_tasks t where t.created_by = p_uid and t.source = 'mgmt' and t.status in ('todo', 'doing') and t.due_date < v_today)
         + (select count(*) from fin_tasks t where t.created_by = p_uid and t.source = 'mgmt' and t.status in ('todo', 'doing') and t.due_date < v_today)
      into v_n;
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

-- ---------------------------------------------------------------- HV Management TEAM (053): tasks done / late / open / overdue now include HR and Finance tasks
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
  -- HR and HV Finance task lists (migration_054); a task is late when it was done after its due day
  st as (
    select 'hr' as src, t.employee_id as emp_id, t.status, t.due_date, (t.completed_at at time zone 'Africa/Cairo')::date as done_on from hr_tasks t
    union all
    select 'fin', coalesce(t.employee_id, (select e.id from employees e where e.user_id = t.assigned_to and e.status = 'active' limit 1)), t.status, t.due_date,
           (t.completed_at at time zone 'Africa/Cairo')::date from fin_tasks t
  ),
  stask as (
    select st.emp_id,
           count(*) filter (where st.src = 'hr' and st.status = 'done' and st.done_on between p_from and v_to) as hr_done,
           count(*) filter (where st.src = 'fin' and st.status = 'done' and st.done_on between p_from and v_to) as fin_done,
           count(*) filter (where st.status = 'done' and st.done_on between p_from and v_to and st.due_date < st.done_on) as done_late,
           count(*) filter (where st.status in ('todo', 'doing')) as open_n,
           count(*) filter (where st.status in ('todo', 'doing') and st.due_date < v_today) as overdue
      from st where st.emp_id is not null
     group by st.emp_id
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
    left join stask on stask.emp_id = emp.id
    left join ent on ent.emp_id = emp.id
    left join expd on expd.emp_id = emp.id
    left join att on att.emp_id = emp.id
    left join lv on lv.emp_id = emp.id
   cross join lateral (
     select coalesce(mtask.done, 0) + coalesce(otask.done, 0) + coalesce(stask.hr_done, 0) + coalesce(stask.fin_done, 0) as done,
            coalesce(mtask.done_late, 0) + coalesce(otask.done_late, 0) + coalesce(stask.done_late, 0) as done_late,
            coalesce(mtask.open_n, 0) + coalesce(otask.open_n, 0) + coalesce(stask.open_n, 0) as open_n,
            coalesce(mtask.overdue, 0) + coalesce(otask.overdue, 0) + coalesce(stask.overdue, 0) as overdue
   ) n
   cross join lateral (
     select jsonb_strip_nulls(jsonb_build_object(
       'kpi_points', round(coalesce(kpi.points, 0), 2),
       'tasks_done', n.done,
       'tasks_done_late', n.done_late,
       'tasks_on_time_pct', case when n.done > 0 then round(100.0 * (n.done - n.done_late) / n.done, 1) end,
       'tasks_open', n.open_n,
       'tasks_overdue', n.overdue,
       'maint_done', coalesce(mtask.done, 0), 'ops_done', coalesce(otask.done, 0),
       'hr_done', coalesce(stask.hr_done, 0), 'fin_done', coalesce(stask.fin_done, 0),
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

-- ---------------------------------------------------------------- who may call what
revoke all on function public.hr_tasks_notify(), public.fin_tasks_notify() from public, anon, authenticated;
revoke all on function public.hr_task_set_status(uuid, text, text), public.fin_task_set_status(uuid, text, text) from public, anon;
grant execute on function public.hr_task_set_status(uuid, text, text), public.fin_task_set_status(uuid, text, text) to authenticated;
revoke all on function public.hv_alerts_hr(uuid), public.hv_alerts_fin(uuid), public.hv_alerts_mgmt(uuid), public.mgmt_team_values(date, date)
  from public, anon, authenticated;
revoke all on function public.mgmt_task_options(), public.mgmt_give_task(text, jsonb), public.mgmt_given_tasks(int) from public, anon;
grant execute on function public.mgmt_task_options(), public.mgmt_give_task(text, jsonb), public.mgmt_given_tasks(int) to authenticated;

notify pgrst, 'reload schema';
