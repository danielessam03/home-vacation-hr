-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_002.sql
-- Module 2: departments, employees (full profile, per-employee work
--           week, salary structure), employee documents + private
--           storage bucket, branch geolocation for GPS check-in,
--           Makadi Heights branch seed.
--
-- ADDITIVE ONLY. Run once in the Supabase SQL editor, after 001.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Branch geolocation (used by module 3 online check-in geofence)
-- ---------------------------------------------------------------------
alter table public.branches add column if not exists latitude  numeric(9,6);
alter table public.branches add column if not exists longitude numeric(9,6);
alter table public.branches add column if not exists geofence_radius_m integer not null default 200;

insert into public.branches (code, name_en, name_ar, address)
values ('MKD', 'Makadi Heights Branch', 'فرع مكادي هايتس', 'Makadi Heights, Red Sea')
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 2. Departments
-- ---------------------------------------------------------------------
create table if not exists public.departments (
  id         uuid primary key default gen_random_uuid(),
  name_en    text not null unique,
  name_ar    text not null,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_departments_touch on public.departments;
create trigger trg_departments_touch before update on public.departments
  for each row execute function public.touch_updated_at();

insert into public.departments (name_en, name_ar) values
  ('Sales',            'المبيعات'),
  ('Marketing',        'التسويق'),
  ('Finance',          'المالية'),
  ('HR & Admin',       'الموارد البشرية والإدارة'),
  ('Operations',       'العمليات'),
  ('Customer Service', 'خدمة العملاء')
on conflict (name_en) do nothing;

-- ---------------------------------------------------------------------
-- 3. Employees
--    weekend_days: per-employee weekend as a JSON array of day numbers
--    (0=Sun .. 5=Fri, 6=Sat). NULL = use the company work_week setting.
--    This is what makes 5-day vs 6-day work weeks per person possible.
-- ---------------------------------------------------------------------
create table if not exists public.employees (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid unique references public.app_users(id),
  employee_code    text unique not null,
  full_name_en     text not null,
  full_name_ar     text not null,
  national_id      text unique check (national_id is null or national_id ~ '^[23][0-9]{13}$'),
  birth_date       date,
  gender           text check (gender in ('male','female')),
  phone            text,
  personal_email   text,
  address          text,
  branch_id        uuid references public.branches(id),
  department_id    uuid references public.departments(id),
  job_title_en     text,
  job_title_ar     text,
  manager_id       uuid references public.employees(id),
  hire_date        date not null,
  contract_type    text not null default 'indefinite'
                   check (contract_type in ('indefinite','fixed_term','part_time','probation')),
  contract_end     date,
  probation_end    date,
  weekend_days     jsonb,
  basic_salary     numeric(14,2) not null default 0,
  allowances       jsonb not null default '[]'::jsonb,  -- [{name_en,name_ar,amount}]
  insurance_base   numeric(14,2) not null default 0,
  nosi_number      text,
  bank_name        text,
  bank_account     text,
  status           text not null default 'active'
                   check (status in ('active','suspended','terminated')),
  termination_date date,
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists idx_employees_branch  on public.employees(branch_id);
create index if not exists idx_employees_dept    on public.employees(department_id);
create index if not exists idx_employees_manager on public.employees(manager_id);
create index if not exists idx_employees_status  on public.employees(status);
create index if not exists idx_employees_user    on public.employees(user_id);

drop trigger if exists trg_employees_touch on public.employees;
create trigger trg_employees_touch before update on public.employees
  for each row execute function public.touch_updated_at();

-- Who am I as an employee? (SECURITY DEFINER: safe inside policies)
create or replace function public.my_employee_id()
returns uuid language sql stable security definer set search_path = public as $fn$
  select id from public.employees where user_id = auth.uid()
$fn$;
grant execute on function public.my_employee_id() to authenticated;

-- ---------------------------------------------------------------------
-- 4. Employee documents (metadata; files live in the private bucket)
-- ---------------------------------------------------------------------
create table if not exists public.employee_documents (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id) on delete cascade,
  doc_type    text not null default 'other'
              check (doc_type in ('national_id','contract','certificate','work_permit','cv','photo','other')),
  title       text not null,
  file_path   text not null,
  expiry_date date,
  uploaded_by uuid references public.app_users(id),
  created_at  timestamptz not null default now()
);
create index if not exists idx_emp_docs_employee on public.employee_documents(employee_id);
create index if not exists idx_emp_docs_expiry   on public.employee_documents(expiry_date);

-- ---------------------------------------------------------------------
-- 5. Private storage bucket for documents
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('employee-docs', 'employee-docs', false)
on conflict (id) do nothing;

drop policy if exists emp_docs_admin_all on storage.objects;
create policy emp_docs_admin_all on storage.objects for all to authenticated
  using ( bucket_id = 'employee-docs' and public.has_role('ceo','hr') )
  with check ( bucket_id = 'employee-docs' and public.has_role('ceo','hr') );

-- Staff can read files inside their own folder (path starts with their
-- employee id). Needed later for self-service payslips/contracts.
drop policy if exists emp_docs_read_own on storage.objects;
create policy emp_docs_read_own on storage.objects for select to authenticated
  using (
    bucket_id = 'employee-docs'
    and (storage.foldername(name))[1] = public.my_employee_id()::text
  );

-- ---------------------------------------------------------------------
-- 6. Row Level Security
-- ---------------------------------------------------------------------
alter table public.departments        enable row level security;
alter table public.employees          enable row level security;
alter table public.employee_documents enable row level security;

drop policy if exists departments_read on public.departments;
create policy departments_read on public.departments for select to authenticated using (true);
drop policy if exists departments_write on public.departments;
create policy departments_write on public.departments for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- employees: ceo/hr/accountant see all; manager sees own team + self;
-- staff sees only their own record. Only ceo/hr write.
drop policy if exists employees_select on public.employees;
create policy employees_select on public.employees for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or user_id = auth.uid()
    or manager_id = public.my_employee_id()
  );

drop policy if exists employees_write on public.employees;
create policy employees_write on public.employees for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

drop policy if exists emp_documents_select on public.employee_documents;
create policy emp_documents_select on public.employee_documents for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or employee_id = public.my_employee_id()
  );

drop policy if exists emp_documents_write on public.employee_documents;
create policy emp_documents_write on public.employee_documents for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );
