-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_058.sql
-- MONTHLY EXCUSE LIMIT (Daniel, 2026-10-28): per employee per month the
-- system refuses more than N hours of excused minutes AND more than M
-- excuses (default 3 h and 3 excuses; Attendance -> Rules edits
-- attendance_policy.excuse_cap {hours, count}; 0 = no limit).
-- Counted: accepted late / longer-break / early-leave notes and the
-- excuses given from the review (each one is an excuse; its minutes add
-- up). Beyond either limit a manager or HR gets EXCUSE_CAP; a CEO may
-- still accept, and the row is marked over_cap. CEOs get a 🔔 line.
-- ADDITIVE ONLY. Safe to re-run. Run after 057.
-- =====================================================================

alter table public.attendance_exceptions add column if not exists over_cap boolean not null default false;

update public.app_settings
   set value = value || jsonb_build_object('excuse_cap', jsonb_build_object('hours', 3, 'count', 3))
 where key = 'attendance_policy' and not (value ? 'excuse_cap');

create or replace function public.excuse_cap()
returns jsonb language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object(
    'minutes', coalesce(((select value -> 'excuse_cap' ->> 'hours' from app_settings where key = 'attendance_policy'))::numeric, 3)::int * 60,
    'count',   coalesce(((select value -> 'excuse_cap' ->> 'count' from app_settings where key = 'attendance_policy'))::numeric, 3)::int);
$fn$;

-- what one employee has already used in the month of p_date (p_skip = the row being decided, not counted twice)
create or replace function public.excuse_used(p_emp uuid, p_date date, p_skip uuid default null)
returns jsonb language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object('minutes', coalesce(sum(coalesce(x.minutes, 0)), 0)::int, 'count', count(*)::int)
    from attendance_exceptions x
   where x.employee_id = p_emp and x.status = 'approved' and x.kind in ('late', 'early_leave', 'break')
     and date_trunc('month', x.exc_date) = date_trunc('month', p_date)
     and (p_skip is null or x.id <> p_skip);
$fn$;

-- would accepting this excuse (p_minutes) go beyond the monthly limit?
create or replace function public.excuse_over_cap(p_emp uuid, p_date date, p_minutes int, p_skip uuid default null)
returns boolean language sql stable security definer set search_path = public as $fn$
  with c as (select public.excuse_cap() c), u as (select public.excuse_used(p_emp, p_date, p_skip) u)
  select ((c.c ->> 'minutes')::int > 0 and (u.u ->> 'minutes')::int + coalesce(p_minutes, 0) > (c.c ->> 'minutes')::int)
      or ((c.c ->> 'count')::int > 0 and (u.u ->> 'count')::int + 1 > (c.c ->> 'count')::int)
    from c, u;
$fn$;

create or replace function public.excuse_cap_guard()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare v_u jsonb; v_c jsonb;
begin
  if new.status <> 'approved' or new.kind not in ('late', 'early_leave', 'break') then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'approved' then return new; end if;
  if public.excuse_over_cap(new.employee_id, new.exc_date, new.minutes, new.id) then
    if public.has_role('ceo') then new.over_cap := true;
    else
      v_u := public.excuse_used(new.employee_id, new.exc_date, new.id); v_c := public.excuse_cap();
      raise exception 'EXCUSE_CAP:%:%:%:%', v_u ->> 'minutes', v_c ->> 'minutes', v_u ->> 'count', v_c ->> 'count' using errcode = 'P0001';
    end if;
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_excuse_cap on public.attendance_exceptions;
create trigger trg_excuse_cap before insert or update of status on public.attendance_exceptions
  for each row execute function public.excuse_cap_guard();

revoke all on function public.excuse_cap(), public.excuse_used(uuid, date, uuid), public.excuse_over_cap(uuid, date, int, uuid) from public, anon;
grant execute on function public.excuse_cap(), public.excuse_used(uuid, date, uuid), public.excuse_over_cap(uuid, date, int, uuid) to authenticated;

-- hv_alerts_hr: same as before plus the CEO line
CREATE OR REPLACE FUNCTION public.hv_alerts_hr(p_uid uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  -- excuses beyond the monthly limit (hours or number): only a CEO may accept them
  if v_role = 'ceo' then
    select count(*) into v_n from attendance_exceptions x
     where x.status = 'pending' and x.kind in ('late', 'early_leave', 'break')
       and public.excuse_over_cap(x.employee_id, x.exc_date, x.minutes, x.id);
    if v_n > 0 then v_items := v_items || jsonb_build_object('en', 'Excuses beyond the monthly limit (CEO only)', 'ar', 'أذونات تتجاوز الحد الشهري (المدير التنفيذي فقط)', 'n', v_n, 'page', 'attendance', 'action', 'att-tab-exceptions'); end if;
  end if;
  return jsonb_build_object('n', (select coalesce(sum((x->>'n')::int), 0) from jsonb_array_elements(v_items) x), 'items', v_items);
end;
$function$;
notify pgrst, 'reload schema';
