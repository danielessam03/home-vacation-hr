-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_006.sql
-- Module 4: leave management per Egyptian labor law.
--   leave_types (annual / casual / sick / unpaid / maternity),
--   leave_requests with the staff -> manager -> HR approval chain,
--   leave_adjustments for manual balance credits/debits,
--   per-employee annual-days override.
--
-- ADDITIVE ONLY. Run once, after 005.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Leave types
-- ---------------------------------------------------------------------
create table if not exists public.leave_types (
  id                  uuid primary key default gen_random_uuid(),
  code                text unique not null,
  name_en             text not null,
  name_ar             text not null,
  is_paid             boolean not null default true,
  pay_percent         numeric(5,2) not null default 100,  -- payroll uses this later
  deducts_from_annual boolean not null default false,
  max_days_per_year   numeric(6,2),                       -- null = no cap
  for_gender          text not null default 'any' check (for_gender in ('any','female','male')),
  is_active           boolean not null default true,
  sort                int not null default 0,
  created_at          timestamptz not null default now()
);

insert into public.leave_types
  (code, name_en, name_ar, is_paid, pay_percent, deducts_from_annual, max_days_per_year, for_gender, sort)
values
  ('annual',    'Annual leave',    'إجازة سنوية',        true, 100, false, null, 'any',    1),
  ('casual',    'Casual leave',    'إجازة عارضة',        true, 100, true,  7,    'any',    2),
  ('sick',      'Sick leave',      'إجازة مرضية',        true, 75,  false, 180,  'any',    3),
  ('unpaid',    'Unpaid leave',    'إجازة بدون مرتب',    false, 0,  false, null, 'any',    4),
  ('maternity', 'Maternity leave', 'إجازة وضع',          true, 100, false, 120,  'female', 5)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------
-- 2. Per-employee override of the annual entitlement (null = by law:
--    21 days, 30 after 10 years of service or age 50)
-- ---------------------------------------------------------------------
alter table public.employees add column if not exists annual_days_override numeric(5,1);

-- ---------------------------------------------------------------------
-- 3. Leave requests + approval chain
-- ---------------------------------------------------------------------
create table if not exists public.leave_requests (
  id                uuid primary key default gen_random_uuid(),
  employee_id       uuid not null references public.employees(id),
  leave_type_id     uuid not null references public.leave_types(id),
  start_date        date not null,
  end_date          date not null,
  days              numeric(6,2) not null check (days > 0),  -- working days, computed by the app
  reason            text,
  status            text not null default 'pending'
                    check (status in ('pending','manager_approved','approved','rejected','cancelled')),
  manager_action_by uuid references public.app_users(id),
  manager_action_at timestamptz,
  manager_note      text,
  hr_action_by      uuid references public.app_users(id),
  hr_action_at      timestamptz,
  hr_note           text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (end_date >= start_date)
);
create index if not exists idx_leave_req_employee on public.leave_requests(employee_id, start_date);
create index if not exists idx_leave_req_status on public.leave_requests(status);

drop trigger if exists trg_leave_req_touch on public.leave_requests;
create trigger trg_leave_req_touch before update on public.leave_requests
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- 4. Manual balance adjustments (carry-over, corrections, encashment)
-- ---------------------------------------------------------------------
create table if not exists public.leave_adjustments (
  id            uuid primary key default gen_random_uuid(),
  employee_id   uuid not null references public.employees(id),
  leave_type_id uuid not null references public.leave_types(id),
  year          int not null,
  days          numeric(6,2) not null,   -- positive = credit, negative = debit
  reason        text not null,
  created_by    uuid references public.app_users(id),
  created_at    timestamptz not null default now()
);
create index if not exists idx_leave_adj_employee on public.leave_adjustments(employee_id, year);

-- ---------------------------------------------------------------------
-- 5. Row Level Security
-- ---------------------------------------------------------------------
alter table public.leave_types       enable row level security;
alter table public.leave_requests    enable row level security;
alter table public.leave_adjustments enable row level security;

drop policy if exists leave_types_read on public.leave_types;
create policy leave_types_read on public.leave_types for select to authenticated using (true);
drop policy if exists leave_types_write on public.leave_types;
create policy leave_types_write on public.leave_types for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- requests: see own; manager sees team; admin sees all
drop policy if exists leave_req_select on public.leave_requests;
create policy leave_req_select on public.leave_requests for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );

-- create: yourself, or HR on anyone's behalf
drop policy if exists leave_req_insert on public.leave_requests;
create policy leave_req_insert on public.leave_requests for insert to authenticated
  with check ( employee_id = public.my_employee_id() or public.has_role('ceo','hr') );

-- update: the owner (to cancel a pending request), the team manager
-- (manager step), or ceo/hr (any step). Status transitions are enforced
-- in the app; every action is audited.
drop policy if exists leave_req_update on public.leave_requests;
create policy leave_req_update on public.leave_requests for update to authenticated
  using (
    public.has_role('ceo','hr')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  )
  with check (
    public.has_role('ceo','hr')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );

drop policy if exists leave_adj_select on public.leave_adjustments;
create policy leave_adj_select on public.leave_adjustments for select to authenticated
  using (
    public.has_role('ceo','hr','accountant')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );
drop policy if exists leave_adj_write on public.leave_adjustments;
create policy leave_adj_write on public.leave_adjustments for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );
