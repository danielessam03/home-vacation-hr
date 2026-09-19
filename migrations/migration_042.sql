-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_042.sql
-- HV Ops (marketing + data entry operations) becomes the 4th system on
-- the unified login, and its results feed the KPI module.
--
-- This file only records the changes made to HR-OWNED tables. The HV Ops
-- schema itself (everything named ops_*) lives in the HV Ops repo:
--   C:\Users\Essam\home-vacation-ops\sql\001 .. 007   (run those; they
--   include the statements below, so running this file is optional)
--
-- ADDITIVE ONLY. Safe to re-run.
-- =====================================================================

-- 1. login: checkbox + role inside HV Ops (managed in HR -> Users)
alter table public.app_users add column if not exists access_ops boolean not null default false;
alter table public.app_users add column if not exists ops_role   text;
do $$ begin
  alter table public.app_users add constraint app_users_ops_role_check
    check (ops_role is null or ops_role in ('admin','manager','data_entry','marketing'));
exception when duplicate_object then null; end $$;

-- 2. KPI module: new category "operations" and new automatic source "ops"
alter table public.kpi_metrics drop constraint if exists kpi_metrics_category_check;
alter table public.kpi_metrics add constraint kpi_metrics_category_check
  check (category in ('sales','property','maintenance','attendance','general','operations'));

alter table public.kpi_entries drop constraint if exists kpi_entries_source_check;
alter table public.kpi_entries add constraint kpi_entries_source_check
  check (source in ('app','engaz','manual','crm','maintenance','ops'));

insert into public.kpi_metrics (code, name_en, name_ar, points_per_unit, value_points_per_million, has_value, sort, category) values
  ('ops_listing_live',    'Listing verified live on website', 'وحدة منشورة ومؤكدة على الموقع',   3, 0, false, 20, 'operations'),
  ('ops_listing_on_time', 'Listing published within SLA',     'وحدة منشورة خلال المهلة (72 ساعة)', 2, 0, false, 21, 'operations'),
  ('ops_task_on_time',    'Ops task approved, on time',       'مهمة تشغيل معتمدة في موعدها',      2, 0, false, 22, 'operations'),
  ('ops_task_late',       'Ops task approved, late',          'مهمة تشغيل معتمدة متأخرة',         1, 0, false, 23, 'operations')
on conflict (code) do nothing;
