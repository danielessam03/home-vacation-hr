-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_046.sql
-- Trips: how the employee travelled (personal car / company car /
-- taxi-Uber). For a taxi the employee may record how much they paid and
-- attach evidence (receipt photo or screenshot) -- both optional, and
-- they can be added after the trip has ended.
-- ADDITIVE ONLY. Run once, after 045.
-- =====================================================================

alter table public.trips add column if not exists transport    text;
alter table public.trips add column if not exists fare_egp     numeric(10,2);
alter table public.trips add column if not exists receipt_path text;
alter table public.trips drop constraint if exists trips_transport_check;
alter table public.trips add constraint trips_transport_check
  check (transport is null or transport in ('personal_car','company_car','taxi'));
alter table public.trips drop constraint if exists trips_fare_check;
alter table public.trips add constraint trips_fare_check check (fare_egp is null or fare_egp >= 0);

-- Private bucket; every file sits in a folder named after the employee id.
insert into storage.buckets (id, name, public)
values ('trip-receipts', 'trip-receipts', false)
on conflict (id) do nothing;

drop policy if exists trip_receipts_insert_own on storage.objects;
create policy trip_receipts_insert_own on storage.objects for insert to authenticated
  with check ( bucket_id = 'trip-receipts'
               and ((storage.foldername(name))[1] = public.my_employee_id()::text or public.has_role('ceo','hr')) );

drop policy if exists trip_receipts_read on storage.objects;
create policy trip_receipts_read on storage.objects for select to authenticated
  using ( bucket_id = 'trip-receipts'
          and ( (storage.foldername(name))[1] = public.my_employee_id()::text
                or public.has_role('ceo','hr','accountant')
                or (storage.foldername(name))[1] in (select id::text from public.employees where manager_id = public.my_employee_id()) ) );

drop policy if exists trip_receipts_delete on storage.objects;
create policy trip_receipts_delete on storage.objects for delete to authenticated
  using ( bucket_id = 'trip-receipts'
          and ((storage.foldername(name))[1] = public.my_employee_id()::text or public.has_role('ceo','hr')) );

-- The owner may only edit a trip while it is open (trips_update). This lets
-- them add or correct the taxi amount / receipt on their own trip afterwards.
create or replace function public.trip_set_fare(p_id uuid, p_fare numeric, p_receipt text)
returns public.trips language plpgsql security definer set search_path = public as $fn$
declare
  v public.trips;
begin
  select * into v from public.trips where id = p_id;
  if v.id is null then raise exception 'trip not found'; end if;
  if not (v.employee_id = public.my_employee_id() or public.has_role('ceo','hr')) then raise exception 'not allowed'; end if;
  if p_fare is not null and p_fare < 0 then raise exception 'bad amount'; end if;
  if p_receipt is not null and split_part(p_receipt, '/', 1) <> v.employee_id::text then raise exception 'bad receipt path'; end if;
  update public.trips set fare_egp = p_fare, receipt_path = coalesce(p_receipt, receipt_path), transport = coalesce(transport, 'taxi')
   where id = p_id returning * into v;
  return v;
end;
$fn$;
revoke all on function public.trip_set_fare(uuid, numeric, text) from public, anon;
grant execute on function public.trip_set_fare(uuid, numeric, text) to authenticated;

notify pgrst, 'reload schema';
