-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_025.sql
-- Lateness rules editable inside the Attendance module (Attendance ->
-- Rules): tiers by minutes after the shift start, e.g. 15 min = notice,
-- 30 min = deduct the late minutes, 60 min = half a day. Payroll applies
-- the highest tier reached, once per day, and records the breakdown.
-- ADDITIVE ONLY. Run once, after 024.
-- =====================================================================

insert into public.app_settings (key, value) values ('attendance_policy', '{
  "tiers": [
    { "from_minutes": 15, "kind": "none",         "value": 0,   "label_en": "Late notice",           "label_ar": "إنذار تأخير" },
    { "from_minutes": 30, "kind": "minutes",      "value": 1,   "label_en": "Late minutes deducted", "label_ar": "خصم دقائق التأخير" },
    { "from_minutes": 60, "kind": "day_fraction", "value": 0.5, "label_en": "Half day deducted",     "label_ar": "خصم نصف يوم" }
  ]
}'::jsonb)
on conflict (key) do nothing;

alter table public.payroll_items add column if not exists late_days   int   not null default 0;
alter table public.payroll_items add column if not exists late_detail jsonb not null default '[]'::jsonb;
