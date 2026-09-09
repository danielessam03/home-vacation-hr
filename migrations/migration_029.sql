-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_029.sql
-- Engaz CRM weekly import: the sales team leader uploads the Engaz
-- leads / closed-deals export (Excel or CSV) in KPIs -> Engaz import.
-- Column matching and agent->employee matching are remembered
-- (import_profiles); every upload is logged (engaz_imports); rows become
-- approved kpi_entries with source 'engaz' and a stable external_id so a
-- re-upload updates instead of double counting.
-- ADDITIVE ONLY. Run once, after 028.
-- =====================================================================

insert into public.kpi_metrics (code, name_en, name_ar, points_per_unit, value_points_per_million, has_value, sort, category)
values ('lead', 'New lead', 'عميل محتمل جديد', 1, 0, false, 0, 'sales')
on conflict (code) do nothing;

create table if not exists public.import_profiles (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null unique check (kind in ('leads','deals')),
  mapping     jsonb not null default '{}'::jsonb,   -- field -> column header
  agents      jsonb not null default '{}'::jsonb,   -- Engaz agent name -> employee id
  options     jsonb not null default '{}'::jsonb,   -- status filter, deal type rule
  updated_by  uuid references public.app_users(id),
  updated_at  timestamptz not null default now()
);
alter table public.import_profiles enable row level security;
drop policy if exists import_profiles_read on public.import_profiles;
create policy import_profiles_read on public.import_profiles for select to authenticated using (true);
drop policy if exists import_profiles_write on public.import_profiles;
create policy import_profiles_write on public.import_profiles for all to authenticated
  using ( public.has_role('ceo','hr','manager') ) with check ( public.has_role('ceo','hr','manager') );

create table if not exists public.engaz_imports (
  id             uuid primary key default gen_random_uuid(),
  kind           text not null check (kind in ('leads','deals')),
  file_name      text,
  rows_total     int not null default 0,
  rows_imported  int not null default 0,
  rows_skipped   int not null default 0,
  period_from    date,
  period_to      date,
  summary        jsonb not null default '{}'::jsonb,  -- per employee counts
  created_by     uuid references public.app_users(id),
  created_at     timestamptz not null default now()
);
alter table public.engaz_imports enable row level security;
drop policy if exists engaz_imports_read on public.engaz_imports;
create policy engaz_imports_read on public.engaz_imports for select to authenticated
  using ( public.has_role('ceo','hr','accountant','manager') );
drop policy if exists engaz_imports_insert on public.engaz_imports;
create policy engaz_imports_insert on public.engaz_imports for insert to authenticated
  with check ( public.has_role('ceo','hr','manager') );
