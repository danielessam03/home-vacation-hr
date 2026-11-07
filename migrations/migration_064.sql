-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_064.sql
-- Trips follow the roads (Daniel, 2026-11-07: "people do not fly").
--   trips.route = { via:'osrm', at, km, legs:[km per leg], geom:[[lat,lng]...] }
--   The app asks the OpenStreetMap routing service (OSRM) for the driving
--   route through the recorded points, in order; the road kilometres become
--   distance_km (and therefore the fuel compensation) and the road path is
--   drawn on the trip map. The employee's phone stores it when the trip ends;
--   trip_set_route fills it in for older trips the first time someone opens
--   their map. manual_km (HR correction) still wins over everything.
-- ADDITIVE ONLY. Safe to re-run. Run after 063.
-- =====================================================================
alter table public.trips add column if not exists route jsonb;

create or replace function public.trip_set_route(p_id uuid, p_route jsonb)
returns public.trips language plpgsql security definer set search_path = public as $fn$
declare
  v  public.trips;
  km numeric;
begin
  select * into v from public.trips where id = p_id;
  if v.id is null then raise exception 'trip not found'; end if;
  if not ( v.employee_id = public.my_employee_id()
           or public.has_role('ceo','hr','accountant')
           or v.employee_id in (select id from public.employees where manager_id = public.my_employee_id()) ) then
    raise exception 'not allowed';
  end if;
  if p_route is null or jsonb_typeof(p_route) <> 'object' or (p_route ->> 'km') is null then raise exception 'bad route'; end if;
  km := (p_route ->> 'km')::numeric;
  if km < 0 or km > 5000 then raise exception 'bad km'; end if;
  update public.trips
     set route = p_route,
         distance_km = case when status = 'closed' then round(km, 2) else distance_km end
   where id = p_id returning * into v;
  return v;
end;
$fn$;
revoke all on function public.trip_set_route(uuid, jsonb) from public, anon;
grant execute on function public.trip_set_route(uuid, jsonb) to authenticated;

notify pgrst, 'reload schema';
