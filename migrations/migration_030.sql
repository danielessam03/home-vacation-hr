-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_030.sql
-- CRM bookings no longer credit anyone on the KPI boards: the login that
-- confirms a booking is the operations admin, not the person who earned
-- it, and bookings carry no agent field. Existing CRM booking entries
-- are removed; the "Booking confirmed" metric is retired (kept for
-- history, inactive). Maintenance tasks keep crediting technicians.
-- ADDITIVE ONLY. Run once, after 029.
-- =====================================================================

create or replace function public.kpi_from_booking()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  -- intentionally no KPI credit for bookings (no agent on the booking)
  return new;
end;
$fn$;

delete from public.kpi_entries where source = 'crm';
update public.kpi_metrics set is_active = false where code = 'booking';
