-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_057.sql
-- HV Management "Give a task" can put the task in a FILE: HR files
-- (hr_task_files, migration_055) and Maintenance files (hv_task_files,
-- migration_056). mgmt_task_options() lists the open files of both
-- systems; mgmt_give_task() accepts p_task.file_id for 'hr' and 'maint'
-- (empty = General tasks). Same two functions as migration_054, re-created.
-- ADDITIVE ONLY. Safe to re-run. Run after 056.
-- =====================================================================

create or replace function public.mgmt_task_options()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
begin
  perform public.mgmt_require();
  return jsonb_build_object(
    'maint', jsonb_build_object(
      'types', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'subtasks', coalesce(t.subtasks, '[]'::jsonb)) order by t.title), '[]'::jsonb) from hv_task_types t),
      'properties', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name) order by p.name), '[]'::jsonb) from hv_properties p),
      'stores', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name), '[]'::jsonb) from hv_stores s),
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'role', u.role) order by u.name), '[]'::jsonb) from hv_users u where coalesce(u.is_active, true)),
      'files', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'status', f.status) order by (f.status = 'complete'), f.created_at desc), '[]'::jsonb) from hv_task_files f where f.status <> 'archived')),
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
                              union all select 'none', 'No department', 'بدون قسم', 1) x),
      'files', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'status', f.status) order by (f.status = 'complete'), f.created_at desc), '[]'::jsonb) from hr_task_files f where f.status <> 'archived')),
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
    if nullif(p_task ->> 'file_id', '') is not null and not exists (select 1 from hv_task_files f where f.id = (p_task ->> 'file_id')::bigint) then raise exception 'FILE_NOT_FOUND'; end if;
    insert into hv_tasks (task_type_id, location_type, property_id, source_store, destination_store, assigned_to, assigned_to_multi,
                          task_date, start_date, end_date, is_range, admin_notes, checked_subtasks, employee_progress, final_revision_by_employee,
                          employee_notes, extra_work, custom_subtasks, audit_trail, recurrence_config, file_id)
    values (v_type.id, v_loc, v_prop, v_src, v_dst, v_people[1], to_jsonb(v_people),
            v_start, v_start, v_end, v_end > v_start, coalesce(p_task ->> 'notes', ''), '[]'::jsonb, '{}'::jsonb, false,
            '', '', v_subs,
            jsonb_build_array(jsonb_build_object('action', 'إنشاء المهمة من HV Management' || case when v_end > v_start then ' (' || v_start || ' → ' || v_end || ')' else '' end || ' مع ' || jsonb_array_length(v_subs) || ' بنود',
                                                 'by', v_by, 'timestamp', now())),
            null, nullif(p_task ->> 'file_id', '')::bigint)
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
      if nullif(p_task ->> 'file_id', '') is not null and not exists (select 1 from hr_task_files f where f.id = (p_task ->> 'file_id')::uuid) then raise exception 'FILE_NOT_FOUND'; end if;
      with ins as (
        insert into hr_tasks (title, description, employee_id, assigned_to, priority, due_date, source, created_by, created_by_name, file_id, sort)
        select v_title, v_desc, e.id, e.user_id, v_prio, v_due, 'mgmt', v_uid, v_me, nullif(p_task ->> 'file_id', '')::uuid,
               coalesce((select max(t.sort) from hr_tasks t where t.file_id is not distinct from nullif(p_task ->> 'file_id', '')::uuid), 0) + row_number() over (order by e.full_name_en)
          from employees e where e.id = any (v_ids)
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
notify pgrst, 'reload schema';
