-- migration_040: maintenance system v6.4 — hand finished tasks to the supervisor
--
-- Before v6.4, when an admin pressed "إنجاز المهمة" (mission complete) the task got an
-- actual_completion_date but NO admin_revised_at, so it never reached the supervisor's
-- "awaiting senior review" queue (they saw it as not reviewed / not done).
-- v6.4 stamps the admin review automatically when an admin finishes a task.
-- This backfills the same stamp on the 51 historical rows (May–Sep 2026) that an
-- admin / supervisor finished themselves, so they now show "بانتظار المراجعة العليا".
--
-- Additive: only fills columns that are NULL; nothing is deleted. Reversible with
--   update hv_tasks set admin_revised_at=null, admin_revised_by=null where id in (...);
-- Run in the Supabase SQL editor (project plwyzkqlbzcikmuurjqg).

update hv_tasks
   set admin_revised_at = actual_completion_date,
       admin_revised_by = completed_by,
       audit_trail = coalesce(audit_trail, '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
         'action', 'مراجعة الإدارة (سُجّلت تلقائياً: المهمة أُنجزت بواسطة الإدارة قبل تحديث 6.4)',
         'by', completed_by,
         'timestamp', actual_completion_date))
 where actual_completion_date is not null
   and admin_revised_at is null
   and completed_by in (select name from hv_users where role in ('admin','admin_supervisor','ceo'));

-- Expected: 51 rows (ids 1,2,3,6,13-25,28,29,33-36,38,50,65,70-72,120,122,135,141,
-- 145-147,150,156,161,162,169,188,198-201,204,206,212,214).
select count(*) filter (where admin_revised_at is not null and supervisor_revised_at is null) as awaiting_supervisor,
       count(*) filter (where admin_revised_at is null and (submitted_at is not null or actual_completion_date is not null)) as awaiting_admin
  from hv_tasks;
