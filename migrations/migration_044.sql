-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_044.sql
-- HV Finance (accounting & finance) becomes the 5th system on the
-- unified login: checkbox + role in HR -> Users, 5th key in
-- hv_my_systems() so every Systems switcher can show it.
--
-- This file only records the changes made to HR-OWNED objects. The
-- HV Finance schema itself (everything named fin_*) lives in
--   C:\Users\Essam\home-vacation-finance\sql\001 .. 005
-- (run those; 001 includes the statements below, so this file is optional)
--
-- ADDITIVE ONLY. Safe to re-run.
-- =====================================================================

alter table public.app_users add column if not exists access_fin boolean not null default false;
alter table public.app_users add column if not exists fin_role   text;
do $$ begin
  alter table public.app_users add constraint app_users_fin_role_check
    check (fin_role is null or fin_role in ('admin','accountant','approver','viewer'));
exception when duplicate_object then null; end $$;

create or replace function public.hv_my_systems()
returns jsonb language sql stable security definer set search_path = public as $fn$
  select coalesce((
    select jsonb_build_object(
      'hr',    a.is_active and coalesce(a.access_hr, false),
      'maint', a.is_active and coalesce(a.access_maint, false),
      'crm',   a.is_active and coalesce(a.access_crm, false),
      'ops',   a.is_active and coalesce(a.access_ops, false),
      'fin',   a.is_active and coalesce(a.access_fin, false))
    from public.app_users a where a.id = auth.uid()
  ), '{"hr":false,"maint":false,"crm":false,"ops":false,"fin":false}'::jsonb)
$fn$;
revoke all on function public.hv_my_systems() from public, anon;
grant execute on function public.hv_my_systems() to authenticated;
