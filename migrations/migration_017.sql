-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_017.sql
-- Unified login resolver: any username from any of the three systems
-- (maintenance username, CRM username) or the email itself resolves to
-- the unified account's email. Returns only the email, nothing else.
-- ADDITIVE ONLY. Run once, after 016.
-- =====================================================================
create or replace function public.hv_login_email(p_username text)
returns text language sql stable security definer set search_path = public as $fn$
  select email from (
    select u.email, 1 as prio from public.hv_users u
     where lower(u.username) = lower(trim(p_username)) and u.is_active and u.auth_user_id is not null
    union all
    select au.email, 2 from public.profiles p join auth.users au on au.id = p.id
     where lower(p.username) = lower(trim(p_username))
    union all
    select a.email, 3 from public.app_users a
     where lower(a.email) = lower(trim(p_username)) and a.is_active
  ) x where email is not null order by prio limit 1
$fn$;
grant execute on function public.hv_login_email(text) to anon, authenticated;
