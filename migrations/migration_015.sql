-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_015.sql
-- Integration, step 3: data flows between the three systems.
--   * CRM: a confirmed booking credits the agent who confirmed it on the
--     sales leaderboard (metric "closing", value = booking amount);
--     cancelling the booking withdraws the credit.
--   * Maintenance: a completed task credits the technician(s) on the
--     leaderboard (new metric "maintenance_task").
--   Entries arrive pre-approved (they are system facts, not self-reports)
--   and carry external_id so nothing is ever counted twice.
-- ADDITIVE ONLY. Run once, after 014.
-- =====================================================================

-- kpi source now also names the two integrated systems
alter table public.kpi_entries drop constraint if exists kpi_entries_source_check;
alter table public.kpi_entries add constraint kpi_entries_source_check
  check (source in ('app','engaz','manual','crm','maintenance'));

insert into public.kpi_metrics (code, name_en, name_ar, points_per_unit, value_points_per_million, has_value, sort)
values ('maintenance_task', 'Maintenance task completed', 'مهمة صيانة منجزة', 3, 0, false, 5)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 1. CRM bookings -> sales KPI
-- ---------------------------------------------------------------------
create or replace function public.kpi_from_booking()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  emp uuid;
  metric uuid;
  prop text;
begin
  select id into metric from public.kpi_metrics where code = 'closing';
  if metric is null then return new; end if;

  if new.status = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    -- the agent = the logged-in CRM user confirming the booking
    select p.employee_id into emp from public.profiles p where p.id = auth.uid();
    if emp is null then return new; end if;
    select coalesce(name, '') into prop from public.properties where id = new.property_id;
    insert into public.kpi_entries (employee_id, metric_id, entry_date, quantity, value_egp, reference, status, source, external_id, approved_at, notes)
    values (emp, metric, coalesce(new.created_at::date, current_date), 1,
            case when coalesce(new.currency, 'EGP') = 'EGP' then new.amount else null end,
            trim(coalesce(new.guest_name, '') || ' · ' || coalesce(prop, '')), 'approved', 'crm',
            'booking:' || new.id, now(), 'CRM booking ' || new.start_date || ' → ' || new.end_date)
    on conflict (external_id) do update set status = 'approved', value_egp = excluded.value_egp;
  elsif new.status = 'cancelled' and old.status is distinct from new.status then
    update public.kpi_entries set status = 'rejected', notes = coalesce(notes, '') || ' | booking cancelled'
     where external_id = 'booking:' || new.id;
  end if;
  return new;
end;
$fn$;

drop trigger if exists trg_kpi_from_booking on public.bookings;
create trigger trg_kpi_from_booking after insert or update of status on public.bookings
  for each row execute function public.kpi_from_booking();

-- ---------------------------------------------------------------------
-- 2. Maintenance tasks -> technician KPI
-- ---------------------------------------------------------------------
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

  for tech in select distinct u.id, u.employee_id from public.hv_users u where u.id = any(ids) and u.employee_id is not null loop
    insert into public.kpi_entries (employee_id, metric_id, entry_date, quantity, reference, status, source, external_id, approved_at, notes)
    values (tech.employee_id, metric, new.actual_completion_date::date, 1,
            'مهمة #' || new.id, 'approved', 'maintenance', 'task:' || new.id || ':' || tech.id, now(), 'Maintenance task completed')
    on conflict (external_id) do nothing;
  end loop;
  return new;
end;
$fn$;

drop trigger if exists trg_kpi_from_task on public.hv_tasks;
create trigger trg_kpi_from_task after insert or update of actual_completion_date on public.hv_tasks
  for each row execute function public.kpi_from_task();

-- backfill: credit tasks already completed (this year), once
do $bf$
declare
  metric uuid; t record; tech record; ids bigint[]; uid_txt text;
begin
  select id into metric from public.kpi_metrics where code = 'maintenance_task';
  for t in select * from public.hv_tasks where actual_completion_date >= date_trunc('year', current_date) loop
    ids := array[]::bigint[];
    if t.assigned_to is not null then ids := ids || t.assigned_to; end if;
    if t.assigned_to_multi is not null and jsonb_typeof(t.assigned_to_multi) = 'array' then
      for uid_txt in select jsonb_array_elements_text(t.assigned_to_multi) loop
        if uid_txt ~ '^[0-9]+$' then ids := ids || uid_txt::bigint; end if;
      end loop;
    end if;
    for tech in select distinct u.id, u.employee_id from public.hv_users u where u.id = any(ids) and u.employee_id is not null loop
      insert into public.kpi_entries (employee_id, metric_id, entry_date, quantity, reference, status, source, external_id, approved_at, notes)
      values (tech.employee_id, metric, t.actual_completion_date::date, 1, 'مهمة #' || t.id, 'approved', 'maintenance', 'task:' || t.id || ':' || tech.id, now(), 'Maintenance task completed (backfilled)')
      on conflict (external_id) do nothing;
    end loop;
  end loop;
end;
$bf$;
