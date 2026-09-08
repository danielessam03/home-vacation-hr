-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_026.sql
-- Break rules: a daily break allowance (default 30 minutes) with penalty
-- tiers for the minutes over it, edited in Attendance -> Rules next to
-- the lateness tiers. Payroll records break minutes and the deduction.
-- ADDITIVE ONLY. Run once, after 025.
-- =====================================================================

update public.app_settings
   set value = value || '{
     "break_max_minutes": 30,
     "break_tiers": [
       { "over_minutes": 1,  "kind": "none",    "value": 0, "label_en": "Break notice",         "label_ar": "إنذار استراحة" },
       { "over_minutes": 15, "kind": "minutes", "value": 1, "label_en": "Extra break deducted", "label_ar": "خصم دقائق الاستراحة الزائدة" }
     ]
   }'::jsonb
 where key = 'attendance_policy' and not (value ? 'break_tiers');

alter table public.payroll_items add column if not exists break_minutes      int           not null default 0;
alter table public.payroll_items add column if not exists break_over_minutes int           not null default 0;
alter table public.payroll_items add column if not exists break_deduction    numeric(14,2) not null default 0;
alter table public.payroll_items add column if not exists break_detail       jsonb         not null default '[]'::jsonb;
