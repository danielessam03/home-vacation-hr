-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_060.sql
-- Rollout day (Daniel, 2026-11-01):
--   * Face check at check-in / check-out from the app: each web punch
--     records whether the selfie matched (face_verified, face_distance).
--     presence_policy.face_punch = 'required' (default) | 'off'.
--   * Laptop agent visibility: employees.agent_last_seen is stamped by
--     every heartbeat (with or without an open session), so HR can see
--     which laptops have the agent running.
-- ADDITIVE ONLY. Safe to re-run. Run after 059.
-- =====================================================================
alter table public.attendance_punches add column if not exists face_verified boolean;
alter table public.attendance_punches add column if not exists face_distance numeric(6,4);
alter table public.employees add column if not exists agent_last_seen timestamptz;

update public.app_settings
   set value = value || jsonb_build_object('face_punch', 'required')
 where key = 'presence_policy' and not (value ? 'face_punch');
notify pgrst, 'reload schema';
