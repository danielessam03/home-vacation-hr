-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_034.sql
-- Early-leave rules: minutes before the shift end are penalised by tiers
-- (Attendance -> Rules), like lateness. Defaults mirror the lateness
-- tiers. An accepted "leaving early" note excuses the day.
-- ADDITIVE ONLY. Run once, after 033.
-- =====================================================================

update public.app_settings
   set value = value || jsonb_build_object('early_tiers', coalesce(value->'tiers', '[]'::jsonb))
 where key = 'attendance_policy' and not (value ? 'early_tiers');

alter table public.payroll_items add column if not exists early_minutes   int           not null default 0;
alter table public.payroll_items add column if not exists early_days      int           not null default 0;
alter table public.payroll_items add column if not exists early_deduction numeric(14,2) not null default 0;
alter table public.payroll_items add column if not exists early_detail    jsonb         not null default '[]'::jsonb;
