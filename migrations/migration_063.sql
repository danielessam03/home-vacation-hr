-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_063.sql
-- Trips (Daniel, 2026-11-07):
--   1. transport 'with_someone' — the employee rode with a colleague or in
--      the client's car: the trip, its locations and km are recorded as
--      usual, but there is NO fuel compensation and no taxi fare.
--   2. trip_set_labels — the app names every recorded point (nearest
--      branch, or the street / area from OpenStreetMap reverse geocoding)
--      and stores the names inside trips.waypoints[i].label so each point
--      is looked up once. Allowed for the owner, HR/CEO and the direct
--      manager (the same people who can read the trip). Only the label is
--      written; t / lat / lng never change.
-- ADDITIVE ONLY. Safe to re-run. Run after 062.
-- =====================================================================
alter table public.trips drop constraint if exists trips_transport_check;
alter table public.trips add constraint trips_transport_check
  check (transport is null or transport in ('personal_car','company_car','taxi','with_someone'));

create or replace function public.trip_set_labels(p_id uuid, p_labels jsonb)
returns public.trips language plpgsql security definer set search_path = public as $fn$
declare
  v   public.trips;
  pts jsonb;
  i   int;
  lbl text;
begin
  select * into v from public.trips where id = p_id;
  if v.id is null then raise exception 'trip not found'; end if;
  if not ( v.employee_id = public.my_employee_id()
           or public.has_role('ceo','hr','accountant')
           or v.employee_id in (select id from public.employees where manager_id = public.my_employee_id()) ) then
    raise exception 'not allowed';
  end if;
  if p_labels is null or jsonb_typeof(p_labels) <> 'object' then raise exception 'bad labels'; end if;
  pts := coalesce(v.waypoints, '[]'::jsonb);
  for i in 0 .. jsonb_array_length(pts) - 1 loop
    lbl := p_labels ->> i::text;
    if lbl is not null and length(lbl) between 1 and 200 then
      pts := jsonb_set(pts, array[i::text, 'label'], to_jsonb(lbl), true);
    end if;
  end loop;
  update public.trips set waypoints = pts where id = p_id returning * into v;
  return v;
end;
$fn$;
revoke all on function public.trip_set_labels(uuid, jsonb) from public, anon;
grant execute on function public.trip_set_labels(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
