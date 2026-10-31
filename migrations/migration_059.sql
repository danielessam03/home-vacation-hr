-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_059.sql
-- Deductions expressed as TIME as well as money (Daniel, 2026-10-31):
-- every lateness / early-leave / break / missing-check-out penalty is
-- a fraction of a day, fixed hours or minutes. Payroll items now keep
-- the sum: deducted_days (fractions of a day) and deducted_minutes
-- (hours + minutes), so Attendance -> Totals can show "1.5 days · 2h 30m".
-- ADDITIVE ONLY. Safe to re-run. Run after 058.
-- =====================================================================
alter table public.payroll_items add column if not exists deducted_days    numeric(8,2) not null default 0;
alter table public.payroll_items add column if not exists deducted_minutes int not null default 0;
notify pgrst, 'reload schema';
