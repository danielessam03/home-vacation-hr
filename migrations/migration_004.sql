-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_004.sql
-- Job roles + AI-generated job descriptions and offers.
--
-- ADDITIVE ONLY. Run once in the Supabase SQL editor, after 003.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Job roles: the reusable definition of each position
-- ---------------------------------------------------------------------
create table if not exists public.job_roles (
  id             uuid primary key default gen_random_uuid(),
  title_en       text not null,
  title_ar       text not null,
  department_id  uuid references public.departments(id),
  duties         text,          -- what they do, free notes
  requirements   text,          -- qualifications / experience notes
  salary_note    text,          -- e.g. "8,000-12,000 EGP + commission"
  commission_note text,         -- commission scheme notes
  benefits       text,          -- insurance, phone line, car allowance...
  schedule_note  text,          -- default working days/hours for the role
  papers         jsonb not null default '[]'::jsonb,  -- required hiring documents
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

drop trigger if exists trg_job_roles_touch on public.job_roles;
create trigger trg_job_roles_touch before update on public.job_roles
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 2. Generated documents (job descriptions and offers), with history
-- ---------------------------------------------------------------------
create table if not exists public.job_documents (
  id             uuid primary key default gen_random_uuid(),
  role_id        uuid not null references public.job_roles(id) on delete cascade,
  doc_kind       text not null default 'jd' check (doc_kind in ('jd','offer')),
  language       text not null default 'both' check (language in ('ar','en','both')),
  candidate_name text,          -- for personalized offers
  custom_notes   text,          -- per-person schedule / special terms
  content_md     text not null,
  created_by     uuid references public.app_users(id),
  created_at     timestamptz not null default now()
);
create index if not exists idx_job_docs_role on public.job_documents(role_id, created_at desc);

-- ---------------------------------------------------------------------
-- 3. RLS -- salaries and offers are sensitive: ceo/hr only
-- ---------------------------------------------------------------------
alter table public.job_roles     enable row level security;
alter table public.job_documents enable row level security;

drop policy if exists job_roles_all on public.job_roles;
create policy job_roles_all on public.job_roles for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

drop policy if exists job_docs_all on public.job_documents;
create policy job_docs_all on public.job_documents for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- ---------------------------------------------------------------------
-- 4. Seed the six main roles with the standard Egyptian hiring papers.
--    Everything here is editable in the app.
-- ---------------------------------------------------------------------
do $seed$
declare
  papers jsonb := jsonb_build_array(
    'بطاقة الرقم القومي (صورة حديثة سارية)',
    'شهادة الميلاد (أصل كمبيوتر حديث)',
    'المؤهل الدراسي (أصل)',
    'شهادة أداء / إعفاء الخدمة العسكرية (للذكور)',
    'صحيفة الحالة الجنائية "فيش وتشبيه" حديثة موجهة لجهة العمل',
    '6 صور شخصية حديثة',
    'كعب عمل / شهادة قيد من مكتب العمل',
    'برنت تأمينات اجتماعية (إفادة بمدد الاشتراك السابقة)',
    'شهادة صحية / كشف طبي حسب طبيعة العمل',
    'إيصال مرافق حديث لإثبات محل الإقامة'
  );
  sales_dept uuid;
  fin_dept   uuid;
  admin_dept uuid;
  mkt_dept   uuid;
  ops_dept   uuid;
begin
  select id into sales_dept from public.departments where name_en = 'Sales';
  select id into fin_dept   from public.departments where name_en = 'Finance';
  select id into admin_dept from public.departments where name_en = 'HR & Admin';
  select id into mkt_dept   from public.departments where name_en = 'Marketing';
  select id into ops_dept   from public.departments where name_en = 'Operations';

  insert into public.job_roles (title_en, title_ar, department_id, duties, requirements, schedule_note, papers)
  select * from (values
    ('Sales Representative', 'مندوب مبيعات عقارية', sales_dept,
     'Sell residential and vacation properties in Hurghada and Makadi. Handle client viewings and site visits, follow up leads in the Engaz CRM, negotiate and close deals, hit monthly sales targets, log every trip and viewing in the HR system.',
     'Sales experience (real estate preferred), good communication in Arabic; English or Russian/German is a plus for foreign buyers. Driving license preferred.',
     '6 days/week, Friday off', papers),
    ('Sales Team Leader', 'قائد فريق مبيعات', sales_dept,
     'Lead a team of sales representatives: set and track monthly targets, coach on viewings and closing, review the team leaderboard, approve team attendance and leave requests, report pipeline and results weekly to management.',
     '3+ years real-estate sales, of which 1+ leading a team. Strong Engaz/CRM discipline.',
     '6 days/week, Friday off', papers),
    ('Accountant', 'محاسب', fin_dept,
     'Handle daily bookkeeping, client payments and receivables, supplier invoices, bank reconciliations, payroll preparation support, Egyptian tax filings (income tax, VAT) and social insurance paperwork with the company accountant.',
     'Accounting degree, 2+ years experience, comfortable with Excel; knowledge of Egyptian tax and NOSI procedures.',
     '5 days/week, Friday-Saturday off', papers),
    ('Admin Officer', 'موظف إداري', admin_dept,
     'Run the office day-to-day: document filing and archiving, contracts preparation, government paperwork follow-up, phone and reception, scheduling, supporting HR with employee files.',
     'Organized, good Arabic writing, basic English, solid computer skills (Word/Excel).',
     '6 days/week, Friday off', papers),
    ('Marketing Data Entry', 'مدخل بيانات تسويق', mkt_dept,
     'Enter and maintain property listings: photos, prices, descriptions in Arabic and English, publish to property portals and social pages, keep the Engaz CRM records clean and current, basic photo editing.',
     'Fast accurate typing in Arabic and English, attention to detail, familiarity with property portals and social media.',
     '6 days/week, Friday off', papers),
    ('Maintenance Employee', 'فني صيانة', ops_dept,
     'Handle maintenance of company-managed units: plumbing, electrical and AC basics, respond to tenant/owner maintenance requests, routine inspections, coordinate external technicians, track spare parts, log every trip in the HR system.',
     'Proven maintenance experience, own basic tools knowledge, driving license preferred.',
     '6 days/week, Friday off', papers)
  ) as v(title_en, title_ar, department_id, duties, requirements, schedule_note, papers)
  where not exists (select 1 from public.job_roles r where r.title_en = v.title_en);
end;
$seed$;
