-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_037.sql
-- "Forgot password" no longer emails the employee (most have placeholder
-- addresses and Supabase's mailer is unreliable). It files a request that
-- HR / the CEO see in Users & roles and resolve by setting a new
-- password from the card.
-- ADDITIVE ONLY. Run once, after 036.
-- =====================================================================

create table if not exists public.password_reset_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.app_users(id) on delete cascade,
  username     text,
  status       text not null default 'pending' check (status in ('pending','done')),
  requested_at timestamptz not null default now(),
  done_by      uuid references public.app_users(id),
  done_at      timestamptz
);
create index if not exists idx_pw_reset_status on public.password_reset_requests(status, requested_at desc);
alter table public.password_reset_requests enable row level security;
drop policy if exists pw_reset_hr on public.password_reset_requests;
create policy pw_reset_hr on public.password_reset_requests for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- callable before login; reveals nothing (true whether or not the name exists)
create or replace function public.request_password_reset(p_username text)
returns boolean language plpgsql security definer set search_path = public as $fn$
declare uid uuid;
begin
  select a.id into uid from public.app_users a
   where a.is_active and (lower(a.username) = lower(p_username) or lower(a.email) = lower(p_username)) limit 1;
  if uid is null then
    select u.auth_user_id into uid from public.hv_users u where lower(u.username) = lower(p_username) and u.is_active limit 1;
  end if;
  if uid is null then return true; end if;
  if not exists (select 1 from public.password_reset_requests r where r.user_id = uid and r.status = 'pending' and r.requested_at > now() - interval '1 hour') then
    insert into public.password_reset_requests (user_id, username) values (uid, p_username);
  end if;
  return true;
end;
$fn$;
grant execute on function public.request_password_reset(text) to anon, authenticated;
