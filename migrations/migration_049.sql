-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_049.sql
-- Cross-system alerts: every Home Vacation system shows a red counter
-- next to the other systems in its 🏢 switcher. One call,
-- public.hv_alert_counts(), returns what is waiting for the signed-in
-- person in each system they may open:
--   { "hr": {"n": 3, "items": [{"en":"Leave requests to approve","ar":"...","n":2}, ...]}, "maint": {...}, ... }
-- Each system's part is its own helper (hv_alerts_hr, hv_alerts_maint,
-- hv_alerts_crm, hv_alerts_ops, hv_alerts_fin) so a system can refine its
-- own definition later without touching the others.
-- ADDITIVE ONLY. Run once, after 048.
-- =====================================================================

-- ---------------------------------------------------------------- HR
create or replace function public.hv_alerts_hr(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_role text;
  v_emp  uuid;
  v_boss boolean;          -- ceo / hr: sees everything
  v_items jsonb := '[]'::jsonb;
  v_n int;
  v_weekend jsonb;
  v_lead boolean;
  v_last timestamptz;
begin
  select a.role into v_role from app_users a where a.id = p_uid and a.is_active and coalesce(a.access_hr, false);
  if v_role is null then return null; end if;
  select e.id into v_emp from employees e where e.user_id = p_uid and e.status = 'active' limit 1;
  v_boss := v_role in ('ceo','hr');

  -- leave requests waiting for me (manager: my team's new ones; HR/CEO: new + manager-approved)
  select count(*) into v_n from leave_requests r join employees e on e.id = r.employee_id
   where (v_boss and r.status in ('pending','manager_approved'))
      or (not v_boss and v_emp is not null and r.status = 'pending' and e.manager_id = v_emp and e.id <> v_emp);
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Leave requests to approve', 'ar', 'طلبات إجازة بانتظار الاعتماد', 'n', v_n, 'page', 'leave'); end if;

  -- late / break / early-leave notes waiting for a decision
  select count(*) into v_n from attendance_exceptions x join employees e on e.id = x.employee_id
   where x.status = 'pending' and x.kind <> 'missing_punch'
     and (v_boss or (v_emp is not null and e.manager_id = v_emp and e.id <> v_emp));
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Attendance notes to decide', 'ar', 'أذونات حضور بانتظار القرار', 'n', v_n, 'page', 'attendance'); end if;

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
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Missing check-outs to decide', 'ar', 'بصمات انصراف ناقصة تحتاج قراراً', 'n', v_n, 'page', 'attendance'); end if;

  -- KPI results waiting for approval
  select count(*) into v_n from kpi_entries k join employees e on e.id = k.employee_id
   where k.status = 'pending' and (v_boss or (v_emp is not null and e.manager_id = v_emp and e.id <> v_emp));
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'KPI results to approve', 'ar', 'نتائج مؤشرات بانتظار الاعتماد', 'n', v_n, 'page', 'kpi'); end if;

  -- make-up day claims
  select count(*) into v_n from leave_makeups m join employees e on e.id = m.employee_id
   where m.status = 'pending' and (v_boss or (v_emp is not null and e.manager_id = v_emp and e.id <> v_emp));
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Make-up day claims', 'ar', 'طلبات أيام تعويض', 'n', v_n, 'page', 'leave'); end if;

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
      v_items := v_items || jsonb_build_object('en', 'Weekly Engaz upload overdue', 'ar', 'تحديث إنجاز الأسبوعي متأخر', 'n', 1, 'page', 'kpi');
    end if;
  end if;

  return jsonb_build_object('n', (select coalesce(sum((x->>'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$fn$;

-- ---------------------------------------------------------------- Maintenance
-- hv_tasks has no status column: a task is "fully submitted" when submitted_at
-- is set or every active assignee has employee_progress[id].submitted_at;
-- reviewed when admin_revised_at / supervisor_revised_at are set.
create or replace function public.hv_alerts_maint(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_me hv_users%rowtype;
  v_items jsonb := '[]'::jsonb;
  v_rev int; v_late int; v_mine int;
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_reviewer boolean;
  v_senior boolean;
begin
  if not exists (select 1 from app_users a where a.id = p_uid and a.is_active and coalesce(a.access_maint, false)) then return null; end if;
  select * into v_me from hv_users u where u.auth_user_id = p_uid and coalesce(u.is_active, true) limit 1;
  if v_me.id is null then return null; end if;
  v_reviewer := v_me.role in ('admin','admin_supervisor','ceo','accountant');
  v_senior := v_me.role in ('admin_supervisor','ceo');

  with a as (
    select t.id, t.submitted_at, t.admin_revised_at, t.supervisor_revised_at, t.actual_completion_date, t.employee_progress,
           coalesce(t.start_date, t.task_date) s, coalesce(t.end_date, t.task_date) e,
           coalesce((select array_agg((x#>>'{}')::bigint) from jsonb_array_elements(case when jsonb_typeof(t.assigned_to_multi) = 'array' and jsonb_array_length(t.assigned_to_multi) > 0 then t.assigned_to_multi else '[]'::jsonb end) x),
                    case when t.assigned_to is not null then array[t.assigned_to] else '{}'::bigint[] end) ids
      from hv_tasks t
  ), b as (
    select a.*,
           (a.submitted_at is not null
            or (cardinality(a.ids) > 0 and not exists (
                  select 1 from unnest(a.ids) i join hv_users u on u.id = i and coalesce(u.is_active, true)
                   where coalesce(a.employee_progress -> i::text ->> 'submitted_at', '') = ''))) as full_sub
      from a
  )
  select
    count(*) filter (where v_reviewer and ((m.admin_revised_at is null and m.full_sub) or (v_senior and m.admin_revised_at is not null and m.supervisor_revised_at is null))),
    count(*) filter (where m.actual_completion_date is null and m.supervisor_revised_at is null and m.admin_revised_at is null and not m.full_sub
                        and m.e < v_today and (v_reviewer or v_me.id = any (m.ids))),
    count(*) filter (where v_me.id = any (m.ids) and m.admin_revised_at is null and m.supervisor_revised_at is null and m.actual_completion_date is null
                        and coalesce(m.employee_progress -> v_me.id::text ->> 'submitted_at', '') = '' and (m.s is null or m.s <= v_today) and not m.full_sub)
    into v_rev, v_late, v_mine
  from b m;

  if v_rev > 0 then v_items := v_items || jsonb_build_object('en', 'Tasks waiting for your review', 'ar', 'مهام بانتظار مراجعتك', 'n', v_rev); end if;
  if v_late > 0 then v_items := v_items || jsonb_build_object('en', 'Late tasks', 'ar', 'مهام متأخرة', 'n', v_late); end if;
  if v_mine > 0 then v_items := v_items || jsonb_build_object('en', 'Your open tasks', 'ar', 'مهامك المفتوحة', 'n', v_mine); end if;
  return jsonb_build_object('n', (select coalesce(sum((x->>'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$fn$;

-- ---------------------------------------------------------------- CRM (property management)
create or replace function public.hv_alerts_crm(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_role text; v_perms jsonb;
  v_items jsonb := '[]'::jsonb;
  v_n int;
  v_today date := (now() at time zone 'Africa/Cairo')::date;
  v_data boolean; v_fin boolean;
begin
  if not exists (select 1 from app_users a where a.id = p_uid and a.is_active and coalesce(a.access_crm, false)) then return null; end if;
  select p.role, coalesce(p.permissions, '[]'::jsonb) into v_role, v_perms from profiles p where p.id = p_uid and coalesce(p.is_active, true);
  if v_role is null then return null; end if;
  v_data := v_role in ('ceo','manager','admin') or v_perms ? 'tab:tasks' or v_perms ? 'tab:calendar';
  v_fin := v_role in ('ceo','manager','accountant') or v_perms ? 'tab:collections';

  if v_data then
    select count(*) into v_n from tasks k where k.status = 'pending' and coalesce(k.end_date, k.start_date) < v_today;
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Overdue property tasks', 'ar', 'مهام عقارات متأخرة', 'n', v_n); end if;
    select count(*) into v_n from bookings b
     where (b.end_date - b.start_date) >= 28 and coalesce(nullif(btrim(b.channel), ''), 'direct') = 'direct'
       and b.status not in ('cancelled','blocked','checked_out') and b.end_date <= v_today + 31;
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Rental contracts ending within 31 days', 'ar', 'عقود إيجار تنتهي خلال 31 يوماً', 'n', v_n); end if;
  end if;
  if v_fin then
    select count(*) into v_n from collections c where c.status = 'pending' and c.due_date <= v_today;
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Collections due', 'ar', 'تحصيلات مستحقة', 'n', v_n); end if;
  end if;
  return jsonb_build_object('n', (select coalesce(sum((x->>'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$fn$;

-- ---------------------------------------------------------------- HV Ops
create or replace function public.hv_alerts_ops(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_role text;
  v_items jsonb := '[]'::jsonb;
  v_n int;
  v_mgr boolean;
begin
  select public.ops_role_of(a)::text into v_role from app_users a where a.id = p_uid and a.is_active and coalesce(a.access_ops, false);
  if v_role is null then return null; end if;
  v_mgr := v_role in ('admin','manager');

  select count(*) into v_n from ops_alerts x where not coalesce(x.is_read, false) and (v_role = 'admin' or x.target_user = p_uid or x.target_role::text = v_role);
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Unread alerts', 'ar', 'تنبيهات غير مقروءة', 'n', v_n); end if;

  select count(*) into v_n from ops_tasks k where k.assigned_to = p_uid and k.status::text in ('todo','doing');
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Your open tasks', 'ar', 'مهامك المفتوحة', 'n', v_n); end if;
  select count(*) into v_n from ops_tasks k where k.assigned_to = p_uid and k.status::text in ('todo','doing') and k.due_at < now();
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Overdue tasks', 'ar', 'مهام متأخرة', 'n', v_n); end if;
  select (select count(*) from ops_listings l where l.assigned_to = p_uid and l.status::text = 'ready_to_publish')
       + (select count(*) from ops_projects l where l.assigned_to = p_uid and l.status::text = 'ready_to_publish') into v_n;
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Ready for you to upload', 'ar', 'جاهز لرفعك', 'n', v_n); end if;
  select count(*) into v_n from ops_photo_requests r where r.assigned_to = p_uid and r.status in ('requested','scheduled');
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Photo shoots assigned to you', 'ar', 'جلسات تصوير مسندة إليك', 'n', v_n); end if;

  if v_mgr then
    select count(*) into v_n from ops_tasks k where k.status::text = 'review';
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Tasks waiting approval', 'ar', 'مهام بانتظار الاعتماد', 'n', v_n); end if;
    select count(*) into v_n from ops_agency_deliverables d where d.status::text = 'submitted';
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Agency deliverables to approve', 'ar', 'تسليمات وكالات بانتظار الاعتماد', 'n', v_n); end if;
    select count(*) into v_n from ops_photo_requests r where r.status = 'shot';
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Photo shoots to approve', 'ar', 'جلسات تصوير بانتظار الاعتماد', 'n', v_n); end if;
  end if;
  return jsonb_build_object('n', (select coalesce(sum((x->>'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$fn$;

-- ---------------------------------------------------------------- HV Finance
create or replace function public.hv_alerts_fin(p_uid uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare
  v_role text;
  v_items jsonb := '[]'::jsonb;
  v_n int;
  v_today date := (now() at time zone 'Africa/Cairo')::date;
begin
  select public.fin_role_of(a) into v_role from app_users a where a.id = p_uid and a.is_active and coalesce(a.access_fin, false);
  if v_role is null then return null; end if;
  if v_role = 'viewer' then return jsonb_build_object('n', 0, 'items', '[]'::jsonb); end if;

  select (select count(*) from fin_journals j where j.status = 'draft' and not exists (select 1 from fin_vouchers v where v.journal_id = j.id))
       + (select count(*) from fin_vouchers v where v.status = 'draft')
       + (select count(*) from fin_invoices i where i.status = 'draft' and i.source_table is not null)
       + (select count(*) from fin_bills b where b.status = 'draft' and b.source_table is not null) into v_n;
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Drafts to post', 'ar', 'مسودات بانتظار الترحيل', 'n', v_n); end if;
  select count(*) into v_n from fin_invoices i where i.kind = 'invoice' and i.status in ('issued','partial') and i.due_date < v_today;
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Overdue invoices', 'ar', 'فواتير متأخرة', 'n', v_n); end if;
  select count(*) into v_n from fin_bills b where b.kind = 'bill' and b.status in ('approved','partial') and b.due_date < v_today;
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Overdue bills', 'ar', 'مستحقات موردين متأخرة', 'n', v_n); end if;
  select count(*) into v_n from fin_tax_returns r where r.status = 'filed' and coalesce(r.amount_due, 0) > 0;
  if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Filed tax returns not yet paid', 'ar', 'إقرارات ضريبية لم تُسدد', 'n', v_n); end if;
  if p_uid = auth.uid() then
    begin
      select count(*) into v_n from public.fin_rent_reminders() r where r.days_left <= 0;
      if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Rent payments due', 'ar', 'إيجارات مستحقة', 'n', v_n); end if;
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('n', (select coalesce(sum((x->>'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$fn$;

-- ---------------------------------------------------------------- one call for the switcher
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
  return v_out;
end;
$fn$;

revoke all on function public.hv_alerts_hr(uuid), public.hv_alerts_maint(uuid), public.hv_alerts_crm(uuid), public.hv_alerts_ops(uuid), public.hv_alerts_fin(uuid) from public, anon, authenticated;
revoke all on function public.hv_alert_counts() from public, anon;
grant execute on function public.hv_alert_counts() to authenticated;
notify pgrst, 'reload schema';
