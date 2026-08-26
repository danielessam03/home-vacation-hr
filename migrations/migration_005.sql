-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_005.sql
-- Split "Sales Representative" into Junior and Senior sales roles.
--
-- ADDITIVE ONLY. Run once in the Supabase SQL editor, after 004.
-- Safe to re-run: both statements are idempotent.
-- =====================================================================

-- 1. The existing seeded role becomes the JUNIOR role (keeps its id, so
--    any documents already generated against it stay linked).
update public.job_roles set
  title_en = 'Junior Sales Representative',
  title_ar = 'مندوب مبيعات عقارية - مبتدئ',
  duties   = 'Handle and qualify incoming leads in the Engaz CRM, schedule and attend client viewings with guidance from senior colleagues, learn the Hurghada and Makadi project portfolio, prepare property presentations, follow up prospects by phone and WhatsApp, log every trip and viewing in the HR system, and hit entry-level monthly targets.',
  requirements = '0-2 years sales experience (real estate a plus), strong communication in Arabic, basic English, presentable, eager to learn, comfortable with mobile apps and CRM. Driving license preferred.'
where title_en = 'Sales Representative';

-- 2. Add the SENIOR role alongside it.
insert into public.job_roles
  (title_en, title_ar, department_id, duties, requirements, schedule_note, papers)
select
  'Senior Sales Representative',
  'مندوب مبيعات عقارية - أول',
  r.department_id,
  'Own the full sales cycle for high-value residential and vacation properties: manage serious buyers including foreign clients, negotiate and close complex deals, maintain a personal pipeline in the Engaz CRM, mentor junior sales representatives on viewings and closing technique, contribute market insight on Hurghada and Makadi pricing, and carry senior-level monthly targets.',
  '3+ years of real-estate sales with a proven closing record, fluent Arabic and working English (Russian or German a strong plus for foreign buyers), confident negotiator, valid driving license.',
  r.schedule_note,
  r.papers
from public.job_roles r
where r.title_en = 'Junior Sales Representative'
  and not exists (select 1 from public.job_roles s where s.title_en = 'Senior Sales Representative');
