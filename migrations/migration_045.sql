-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_045.sql
-- Engaz "clients" export (two sheets: clients + follow-ups with the
-- sales rep and stage) is read as one file: kind 'clients'. Adds the
-- 'follow_up' KPI (one per logged follow-up in Engaz).
-- ADDITIVE ONLY. Run once, after 044.
-- =====================================================================

alter table public.import_profiles drop constraint if exists import_profiles_kind_check;
alter table public.import_profiles add constraint import_profiles_kind_check check (kind in ('leads','deals','clients'));
alter table public.engaz_imports drop constraint if exists engaz_imports_kind_check;
alter table public.engaz_imports add constraint engaz_imports_kind_check check (kind in ('leads','deals','clients'));

insert into public.kpi_metrics (code, name_en, name_ar, points_per_unit, value_points_per_million, has_value, sort, category)
values ('follow_up', 'Client follow-up (Engaz)', 'متابعة عميل (إنجاز)', 0.5, 0, false, 1, 'sales')
on conflict (code) do nothing;

notify pgrst, 'reload schema';

-- One call writes the whole file: upserts the KPI rows the file produces
-- and removes earlier Engaz rows of the same clients that the file no
-- longer produces (reassigned lead, deleted follow-up, rep unmatched).
-- The sales team leader (manager) may import for every rep, not only
-- the people reporting to them.
create or replace function public.engaz_import_clients(p_entries jsonb, p_clients text[])
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_ids text[];
  v_up int := 0;
  v_del int := 0;
begin
  if not public.has_role('ceo','hr','manager') then raise exception 'not allowed'; end if;

  select coalesce(array_agg(x->>'external_id'), '{}') into v_ids from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) x;
  if exists (select 1 from unnest(v_ids) i where i is null or i not like 'engaz:c:%') then raise exception 'bad external id'; end if;

  insert into public.kpi_entries (employee_id, metric_id, entry_date, quantity, value_egp, reference, status, source, external_id, approved_at, created_by, notes)
  select (x->>'employee_id')::uuid, m.id, (x->>'entry_date')::date, 1, null, nullif(x->>'reference', ''), 'approved', 'engaz',
         x->>'external_id', now(), auth.uid(), x->>'notes'
    from jsonb_array_elements(p_entries) x
    join public.kpi_metrics m on m.code = x->>'code' and m.code in ('lead','follow_up','viewing','closing','rental')
    join public.employees e on e.id = (x->>'employee_id')::uuid
  on conflict (external_id) do update
     set employee_id = excluded.employee_id, metric_id = excluded.metric_id, entry_date = excluded.entry_date,
         reference = excluded.reference, notes = excluded.notes, status = 'approved';
  get diagnostics v_up = row_count;

  delete from public.kpi_entries k
   where k.source = 'engaz' and k.external_id like 'engaz:c:%'
     and split_part(k.external_id, ':', 4) = any (coalesce(p_clients, '{}'))
     and not (k.external_id = any (v_ids));
  get diagnostics v_del = row_count;

  return jsonb_build_object('upserted', v_up, 'removed', v_del);
end;
$fn$;
revoke all on function public.engaz_import_clients(jsonb, text[]) from public, anon;
grant execute on function public.engaz_import_clients(jsonb, text[]) to authenticated;

notify pgrst, 'reload schema';
