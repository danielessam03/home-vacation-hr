-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_061.sql
-- Where may a person check in from the app? (Daniel, 2026-11-01)
--   employees.offsite_mode
--     'office'   (default) check-in only inside a branch zone; check-out
--                anywhere, but outside the zone a reason must be typed
--     'anywhere' check-in anywhere (location recorded); outside the zone
--                a reason is typed at check-in and check-out
--     'site'     site work (maintenance): check-in and check-out anywhere,
--                location recorded, no reason needed
--   attendance_punches.offsite_reason  the typed reason
-- ADDITIVE ONLY. Safe to re-run. Run after 060.
-- =====================================================================
alter table public.employees add column if not exists offsite_mode text not null default 'office';
alter table public.employees drop constraint if exists employees_offsite_mode_chk;
alter table public.employees add constraint employees_offsite_mode_chk check (offsite_mode in ('office', 'anywhere', 'site'));
alter table public.attendance_punches add column if not exists offsite_reason text;
notify pgrst, 'reload schema';
