-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_031.sql
-- Maintenance tasks credit only ACTIVE maintenance accounts. A task
-- assigned to a suspended account (someone without maintenance access)
-- earns no KPI points.
-- ADDITIVE ONLY. Run once, after 030.
-- =====================================================================

create or replace function public.kpi_from_task()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  metric uuid;
  uid_txt text;
  tech record;
  ids bigint[];
begin
  if new.actual_completion_date is null or (tg_op = 'UPDATE' and old.actual_completion_date is not null) then
    return new;
  end if;
  select id into metric from public.kpi_metrics where code = 'maintenance_task';
  if metric is null then return new; end if;

  ids := array[]::bigint[];
  if new.assigned_to is not null then ids := ids || new.assigned_to; end if;
  if new.assigned_to_multi is not null and jsonb_typeof(new.assigned_to_multi) = 'array' then
    for uid_txt in select jsonb_array_elements_text(new.assigned_to_multi) loop
      if uid_txt ~ '^[0-9]+$' then ids := ids || uid_txt::bigint; end if;
    end loop;
  end if;

  for tech in select distinct u.id, u.employee_id from public.hv_users u
              where u.id = any(ids) and u.employee_id is not null and u.is_active loop
    insert into public.kpi_entries (employee_id, metric_id, entry_date, quantity, reference, status, source, external_id, approved_at, notes)
    values (tech.employee_id, metric, new.actual_completion_date::date, 1,
            'مهمة #' || new.id, 'approved', 'maintenance', 'task:' || new.id || ':' || tech.id, now(), 'Maintenance task completed')
    on conflict (external_id) do nothing;
  end loop;
  return new;
end;
$fn$;
