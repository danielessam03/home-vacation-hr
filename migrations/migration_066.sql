-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_066.sql
-- Taxi / Uber trips: MANY rides per trip (Daniel, 2026-11-18). One logged
-- trip with a client may contain several Uber rides between viewings; the
-- employee attaches every receipt with its own amount, during the trip or
-- any time after it has ended.
--   trips.receipts = [{ id, path|null, amount|null, note|null, at, by }]
--   fare_egp = sum of the ride amounts whenever any ride has one (month
--   totals keep working); receipt_path stays as the legacy single file.
-- ADDITIVE ONLY. Safe to re-run. Run after 065.
-- =====================================================================
alter table public.trips add column if not exists receipts jsonb not null default '[]'::jsonb;

-- legacy: the single receipt / amount becomes the first ride
update public.trips
   set receipts = jsonb_build_array(jsonb_build_object('id', gen_random_uuid()::text, 'path', receipt_path, 'amount', fare_egp, 'note', null, 'at', coalesce(updated_at, created_at), 'by', null, 'legacy', true))
 where transport = 'taxi' and (receipt_path is not null or fare_egp is not null) and (receipts is null or receipts = '[]'::jsonb);

create or replace function public.trip_receipts_total(p jsonb) returns numeric language sql immutable as $$
  select sum((r ->> 'amount')::numeric) from jsonb_array_elements(coalesce(p, '[]'::jsonb)) r where (r ->> 'amount') is not null
$$;

create or replace function public.trip_add_receipt(p_id uuid, p_path text, p_amount numeric, p_note text default null)
returns public.trips language plpgsql security definer set search_path = public as $fn$
declare
  v public.trips;
  entry jsonb;
begin
  select * into v from public.trips where id = p_id;
  if v.id is null then raise exception 'trip not found'; end if;
  if not (v.employee_id = public.my_employee_id() or public.has_role('ceo','hr')) then raise exception 'not allowed'; end if;
  if p_path is null and p_amount is null then raise exception 'nothing to add'; end if;
  if p_amount is not null and p_amount < 0 then raise exception 'bad amount'; end if;
  if p_path is not null and split_part(p_path, '/', 1) <> v.employee_id::text then raise exception 'bad receipt path'; end if;
  entry := jsonb_build_object('id', gen_random_uuid()::text, 'path', p_path, 'amount', p_amount, 'note', nullif(left(p_note, 200), ''), 'at', now(), 'by', auth.uid());
  update public.trips
     set receipts = coalesce(receipts, '[]'::jsonb) || entry,
         transport = coalesce(transport, 'taxi'),
         fare_egp = coalesce(public.trip_receipts_total(coalesce(receipts, '[]'::jsonb) || entry), fare_egp),
         receipt_path = coalesce(receipt_path, p_path)
   where id = p_id returning * into v;
  return v;
end;
$fn$;
revoke all on function public.trip_add_receipt(uuid, text, numeric, text) from public, anon;
grant execute on function public.trip_add_receipt(uuid, text, numeric, text) to authenticated;

create or replace function public.trip_remove_receipt(p_id uuid, p_rid text)
returns public.trips language plpgsql security definer set search_path = public as $fn$
declare
  v public.trips;
  rest jsonb;
begin
  select * into v from public.trips where id = p_id;
  if v.id is null then raise exception 'trip not found'; end if;
  if not (v.employee_id = public.my_employee_id() or public.has_role('ceo','hr')) then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(r), '[]'::jsonb) into rest from jsonb_array_elements(coalesce(v.receipts, '[]'::jsonb)) r where r ->> 'id' <> p_rid;
  update public.trips
     set receipts = rest,
         fare_egp = case when jsonb_array_length(rest) = 0 then null else coalesce(public.trip_receipts_total(rest), fare_egp) end,
         receipt_path = (select r ->> 'path' from jsonb_array_elements(rest) r where (r ->> 'path') is not null limit 1)
   where id = p_id returning * into v;
  return v;
end;
$fn$;
revoke all on function public.trip_remove_receipt(uuid, text) from public, anon;
grant execute on function public.trip_remove_receipt(uuid, text) to authenticated;

notify pgrst, 'reload schema';
