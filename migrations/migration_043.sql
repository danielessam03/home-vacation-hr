-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_043.sql
-- One question every system asks at login: "which Home Vacation systems
-- may THIS account open?"  The answer drives the Systems switcher in all
-- four apps (HR, Maintenance, CRM, HV Ops) so a person only ever sees
-- links to the systems ticked for them in HR -> Users.
--
-- Read-only, returns only the caller's own four flags. A disabled login
-- gets all four = false.
-- ADDITIVE ONLY. Safe to re-run.
-- =====================================================================

create or replace function public.hv_my_systems()
returns jsonb language sql stable security definer set search_path = public as $fn$
  select coalesce((
    select jsonb_build_object(
      'hr',    a.is_active and coalesce(a.access_hr, false),
      'maint', a.is_active and coalesce(a.access_maint, false),
      'crm',   a.is_active and coalesce(a.access_crm, false),
      'ops',   a.is_active and coalesce(a.access_ops, false))
    from public.app_users a where a.id = auth.uid()
  ), '{"hr":false,"maint":false,"crm":false,"ops":false}'::jsonb)
$fn$;

revoke all on function public.hv_my_systems() from public, anon;
grant execute on function public.hv_my_systems() to authenticated;
