-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_003.sql
-- Module 3: shifts, attendance punches (device + web GPS + manual),
--           geofenced online check-in, car trips with km tracing,
--           monthly attendance locks.
--
-- ADDITIVE ONLY. Run once in the Supabase SQL editor, after 002.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Shifts
-- ---------------------------------------------------------------------
create table if not exists public.shifts (
  id                  uuid primary key default gen_random_uuid(),
  name_en             text not null,
  name_ar             text not null,
  start_time          time not null default '09:00',
  end_time            time not null default '17:00',
  grace_minutes       int  not null default 15,   -- lateness allowed before counting
  min_overtime_minutes int not null default 30,   -- OT under this is ignored
  is_active           boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

drop trigger if exists trg_shifts_touch on public.shifts;
create trigger trg_shifts_touch before update on public.shifts
  for each row execute function public.touch_updated_at();

insert into public.shifts (name_en, name_ar, start_time, end_time)
select 'Standard 9-5', 'الوردية الأساسية 9-5', '09:00', '17:00'
where not exists (select 1 from public.shifts);

alter table public.employees add column if not exists shift_id uuid references public.shifts(id);
alter table public.employees add column if not exists device_code text;  -- code on the ZKTeco device
create index if not exists idx_employees_device on public.employees(device_code);

-- ---------------------------------------------------------------------
-- 2. Attendance punches
--    source: bridge (ZKTeco via edge function) | web (phone GPS button)
--            | manual (HR entry, always audited)
-- ---------------------------------------------------------------------
create table if not exists public.attendance_punches (
  id                   uuid primary key default gen_random_uuid(),
  employee_id          uuid references public.employees(id),
  employee_device_code text not null default '',
  punch_time           timestamptz not null,
  direction            text not null default 'unknown' check (direction in ('in','out','unknown')),
  device_id            text not null default 'web',
  source               text not null default 'web' check (source in ('device','bridge','web','manual')),
  latitude             numeric(9,6),
  longitude            numeric(9,6),
  accuracy_m           numeric(8,1),
  within_geofence      boolean,
  branch_id            uuid references public.branches(id),
  note                 text,
  created_by           uuid references public.app_users(id),
  created_at           timestamptz not null default now()
);

-- dedupe target for the bridge (same person, same second, same device)
create unique index if not exists uq_punch_dedupe
  on public.attendance_punches(employee_device_code, punch_time, device_id);
create index if not exists idx_punch_employee_time on public.attendance_punches(employee_id, punch_time);
create index if not exists idx_punch_time on public.attendance_punches(punch_time);

-- ---------------------------------------------------------------------
-- 3. Monthly locks (per branch). Once locked, punches in that month
--    cannot be added, changed or removed -- enforced by trigger, so it
--    also binds HR and the CEO.
-- ---------------------------------------------------------------------
create table if not exists public.attendance_locks (
  id        uuid primary key default gen_random_uuid(),
  year      int not null,
  month     int not null check (month between 1 and 12),
  branch_id uuid not null references public.branches(id),
  locked_by uuid references public.app_users(id),
  locked_at timestamptz not null default now(),
  unique (year, month, branch_id)
);

create or replace function public.check_attendance_lock()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  emp_branch uuid;
  pt timestamptz;
begin
  pt := coalesce(new.punch_time, old.punch_time);
  select branch_id into emp_branch from public.employees
   where id = coalesce(new.employee_id, old.employee_id);
  if exists (
    select 1 from public.attendance_locks
     where branch_id = emp_branch
       and year  = extract(year  from pt at time zone 'Africa/Cairo')::int
       and month = extract(month from pt at time zone 'Africa/Cairo')::int
  ) then
    raise exception 'ATTENDANCE_LOCKED: this month is locked for the employee''s branch';
  end if;
  return coalesce(new, old);
end;
$fn$;

drop trigger if exists trg_punch_lock on public.attendance_punches;
create trigger trg_punch_lock before insert or update or delete on public.attendance_punches
  for each row execute function public.check_attendance_lock();

-- ---------------------------------------------------------------------
-- 4. Car trips -- employees log every drive; km traced from GPS points
--    waypoints: [{t: iso timestamp, lat, lng}], distance_km computed
--    from the point chain; manual_km lets HR correct against odometer.
-- ---------------------------------------------------------------------
create table if not exists public.trips (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  purpose     text,
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  waypoints   jsonb not null default '[]'::jsonb,
  distance_km numeric(8,2),
  manual_km   numeric(8,2),
  status      text not null default 'open' check (status in ('open','closed')),
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_trips_employee on public.trips(employee_id, started_at);
create index if not exists idx_trips_status on public.trips(status);

drop trigger if exists trg_trips_touch on public.trips;
create trigger trg_trips_touch before update on public.trips
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 5. Row Level Security
-- ---------------------------------------------------------------------
alter table public.shifts             enable row level security;
alter table public.attendance_punches enable row level security;
alter table public.attendance_locks   enable row level security;
alter table public.trips              enable row level security;

drop policy if exists shifts_read on public.shifts;
create policy shifts_read on public.shifts for select to authenticated using (true);
drop policy if exists shifts_write on public.shifts;
create policy shifts_write on public.shifts for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- punches: see own; manager sees team; admin sees all
drop policy if exists punches_select on public.attendance_punches;
create policy punches_select on public.attendance_punches for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );

-- insert: self web punch, or HR/CEO manual entry
drop policy if exists punches_insert on public.attendance_punches;
create policy punches_insert on public.attendance_punches for insert to authenticated
  with check (
    (source = 'web' and employee_id = public.my_employee_id())
    or (source = 'manual' and public.has_role('ceo','hr'))
  );

drop policy if exists punches_update on public.attendance_punches;
create policy punches_update on public.attendance_punches for update to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );
drop policy if exists punches_delete on public.attendance_punches;
create policy punches_delete on public.attendance_punches for delete to authenticated
  using ( public.has_role('ceo','hr') );

drop policy if exists locks_read on public.attendance_locks;
create policy locks_read on public.attendance_locks for select to authenticated
  using ( public.has_role('ceo','hr','accountant','manager') );
drop policy if exists locks_write on public.attendance_locks;
create policy locks_write on public.attendance_locks for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- trips: own + team + admin; staff manage their own open trip
drop policy if exists trips_select on public.trips;
create policy trips_select on public.trips for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );

drop policy if exists trips_insert on public.trips;
create policy trips_insert on public.trips for insert to authenticated
  with check ( employee_id = public.my_employee_id() or public.has_role('ceo','hr') );

drop policy if exists trips_update on public.trips;
create policy trips_update on public.trips for update to authenticated
  using ( (employee_id = public.my_employee_id() and status = 'open') or public.has_role('ceo','hr') )
  with check ( employee_id = public.my_employee_id() or public.has_role('ceo','hr') );

drop policy if exists trips_delete on public.trips;
create policy trips_delete on public.trips for delete to authenticated
  using ( public.has_role('ceo','hr') );
