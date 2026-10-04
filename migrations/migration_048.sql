-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_048.sql
-- Missing check-out: if nobody decides within N days, a default penalty
-- applies by itself (still changeable by a decision afterwards). The rule
-- lives in app_settings.attendance_policy.missing_punch and is edited in
-- Attendance -> Rules. It only covers days from `from` onward, so older
-- undecided days are not penalised retroactively.
-- ADDITIVE ONLY. Run once, after 047.
-- =====================================================================

update public.app_settings
   set value = value || jsonb_build_object('missing_punch',
         jsonb_build_object('enabled', true, 'days', 3, 'kind', 'day_fraction', 'value', 0.25, 'from', '2026-10-04'))
 where key = 'attendance_policy' and not (value ? 'missing_punch');
