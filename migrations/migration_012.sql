-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_012.sql
-- Live work sessions: idle detection (browser + laptop agent), "still
-- working?" challenges answered with a selfie face-match, automatic
-- breaks, face enrollments, per-employee agent tokens.
--
-- ADDITIVE ONLY. Run once, after 011.
-- =====================================================================

alter table public.employees add column if not exists agent_token text unique;

insert into public.app_settings (key, value) values
  ('presence_policy', jsonb_build_object(
     'idle_minutes', 10,            -- no activity for this long -> prompt
     'prompt_timeout_minutes', 5,   -- unanswered prompt -> automatic break
     'face_threshold', 0.5,         -- max face-descriptor distance to accept
     'heartbeat_seconds', 60
   ))
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 1. Work sessions (one per check-in)
-- ---------------------------------------------------------------------
create table if not exists public.work_sessions (
  id                uuid primary key default gen_random_uuid(),
  employee_id       uuid not null references public.employees(id),
  started_at        timestamptz not null default now(),
  ended_at          timestamptz,
  status            text not null default 'working' check (status in ('working','break','ended')),
  last_activity_at  timestamptz not null default now(),   -- max(browser, agent)
  last_heartbeat_at timestamptz not null default now(),
  agent_seen_at     timestamptz,
  break_started_at  timestamptz,
  break_seconds     int not null default 0,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create index if not exists idx_ws_employee on public.work_sessions(employee_id, started_at desc);
create index if not exists idx_ws_open on public.work_sessions(status) where status <> 'ended';

drop trigger if exists trg_ws_touch on public.work_sessions;
create trigger trg_ws_touch before update on public.work_sessions
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 2. Session events (audit of what happened during the session)
-- ---------------------------------------------------------------------
create table if not exists public.session_events (
  id          bigserial primary key,
  session_id  uuid not null references public.work_sessions(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  kind        text not null,   -- start | prompt | confirm | face_fail | break_start | break_end | end | agent_idle
  meta        jsonb,
  at          timestamptz not null default now()
);
create index if not exists idx_se_session on public.session_events(session_id, at);

-- ---------------------------------------------------------------------
-- 3. Face enrollments (128-d descriptor, averaged over samples).
--    Readable only by ceo/hr -- verification is done server-side so an
--    employee can never read or forge their own reference.
-- ---------------------------------------------------------------------
create table if not exists public.face_enrollments (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  descriptor  jsonb not null,
  samples     int not null default 1,
  enrolled_by uuid references public.app_users(id),
  enrolled_at timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. "Still working?" challenges
-- ---------------------------------------------------------------------
create table if not exists public.presence_challenges (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references public.work_sessions(id) on delete cascade,
  employee_id   uuid not null references public.employees(id),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  answered_at   timestamptz,
  answered_via  text check (answered_via in ('laptop','phone')),
  face_distance numeric(6,4),
  attempts      int not null default 0,
  result        text check (result in ('confirmed','timeout','failed'))
);
create index if not exists idx_pc_open on public.presence_challenges(employee_id) where result is null;

-- ---------------------------------------------------------------------
-- 5. RLS
-- ---------------------------------------------------------------------
alter table public.work_sessions       enable row level security;
alter table public.session_events      enable row level security;
alter table public.face_enrollments    enable row level security;
alter table public.presence_challenges enable row level security;

-- sessions: own + team + admin read; own insert/update; ceo/hr all
drop policy if exists ws_select on public.work_sessions;
create policy ws_select on public.work_sessions for select to authenticated
  using ( public.has_role('ceo','hr','accountant') or employee_id = public.my_employee_id()
          or employee_id in (select id from public.employees where manager_id = public.my_employee_id()) );
drop policy if exists ws_insert on public.work_sessions;
create policy ws_insert on public.work_sessions for insert to authenticated
  with check ( employee_id = public.my_employee_id() or public.has_role('ceo','hr') );
drop policy if exists ws_update on public.work_sessions;
create policy ws_update on public.work_sessions for update to authenticated
  using ( employee_id = public.my_employee_id() or public.has_role('ceo','hr') )
  with check ( employee_id = public.my_employee_id() or public.has_role('ceo','hr') );

drop policy if exists se_select on public.session_events;
create policy se_select on public.session_events for select to authenticated
  using ( public.has_role('ceo','hr','accountant') or employee_id = public.my_employee_id()
          or employee_id in (select id from public.employees where manager_id = public.my_employee_id()) );
drop policy if exists se_insert on public.session_events;
create policy se_insert on public.session_events for insert to authenticated
  with check ( employee_id = public.my_employee_id() or public.has_role('ceo','hr') );

-- face reference: ceo/hr only (written through the edge function)
drop policy if exists fe_admin on public.face_enrollments;
create policy fe_admin on public.face_enrollments for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- challenges: own + team + admin read; own insert (client raises the prompt);
-- results are written server-side only (no client update policy)
drop policy if exists pc_select on public.presence_challenges;
create policy pc_select on public.presence_challenges for select to authenticated
  using ( public.has_role('ceo','hr','accountant') or employee_id = public.my_employee_id()
          or employee_id in (select id from public.employees where manager_id = public.my_employee_id()) );
drop policy if exists pc_insert on public.presence_challenges;
create policy pc_insert on public.presence_challenges for insert to authenticated
  with check ( employee_id = public.my_employee_id() );

-- an unanswered prompt may be closed as 'timeout' by the employee's own
-- device (any other result is written only by the presence edge function)
drop policy if exists pc_timeout on public.presence_challenges;
create policy pc_timeout on public.presence_challenges for update to authenticated
  using ( employee_id = public.my_employee_id() and result is null )
  with check ( employee_id = public.my_employee_id() and result = 'timeout' );
