-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_010.sql
-- Sales KPIs & leaderboard: editable metrics with points, self-reported
-- entries approved by the manager, monthly competition visible to all.
-- Engaz CRM sync slot: entries.source = 'engaz' + external_id (unique)
-- so a future sync can upsert without duplicates.
--
-- ADDITIVE ONLY. Run once, after 009.
-- =====================================================================

create table if not exists public.kpi_metrics (
  id                       uuid primary key default gen_random_uuid(),
  code                     text unique not null,
  name_en                  text not null,
  name_ar                  text not null,
  points_per_unit          numeric(8,2) not null default 1,
  value_points_per_million numeric(8,2) not null default 0,  -- extra points per 1M EGP of deal value
  has_value                boolean not null default false,    -- entry carries an EGP amount
  is_active                boolean not null default true,
  sort                     int not null default 0,
  created_at               timestamptz not null default now()
);

insert into public.kpi_metrics (code, name_en, name_ar, points_per_unit, value_points_per_million, has_value, sort) values
  ('listing', 'New listing acquired', 'وحدة جديدة مضافة',   5,  0,  false, 1),
  ('viewing', 'Client viewing',       'معاينة عميل',          2,  0,  false, 2),
  ('offer',   'Offer submitted',      'عرض شراء مقدم',        5,  0,  false, 3),
  ('closing', 'Deal closed',          'صفقة مغلقة',          50, 10, true,  4)
on conflict (code) do nothing;

create table if not exists public.kpi_entries (
  id          uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  metric_id   uuid not null references public.kpi_metrics(id),
  entry_date  date not null default current_date,
  quantity    numeric(8,2) not null default 1 check (quantity > 0),
  value_egp   numeric(14,2),
  reference   text,            -- client / unit / project
  notes       text,
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  approved_by uuid references public.app_users(id),
  approved_at timestamptz,
  source      text not null default 'app' check (source in ('app','engaz','manual')),
  external_id text unique,     -- CRM record id for dedupe on sync
  created_by  uuid references public.app_users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists idx_kpi_entries_emp_date on public.kpi_entries(employee_id, entry_date);
create index if not exists idx_kpi_entries_status on public.kpi_entries(status);

drop trigger if exists trg_kpi_entries_touch on public.kpi_entries;
create trigger trg_kpi_entries_touch before update on public.kpi_entries
  for each row execute function public.touch_updated_at();

drop trigger if exists trg_audit_kpi_entries on public.kpi_entries;
create trigger trg_audit_kpi_entries after insert or update or delete on public.kpi_entries
  for each row execute function public.audit_row_change();

alter table public.kpi_metrics enable row level security;
alter table public.kpi_entries enable row level security;

drop policy if exists kpi_metrics_read on public.kpi_metrics;
create policy kpi_metrics_read on public.kpi_metrics for select to authenticated using (true);
drop policy if exists kpi_metrics_write on public.kpi_metrics;
create policy kpi_metrics_write on public.kpi_metrics for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );

-- approved entries are visible to everyone (that's the leaderboard);
-- pending/rejected only to the owner, their manager, and admins
drop policy if exists kpi_entries_select on public.kpi_entries;
create policy kpi_entries_select on public.kpi_entries for select to authenticated
  using (
    status = 'approved'
    or public.has_role('ceo','hr')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );

drop policy if exists kpi_entries_insert on public.kpi_entries;
create policy kpi_entries_insert on public.kpi_entries for insert to authenticated
  with check (
    employee_id = public.my_employee_id()
    or public.has_role('ceo','hr')
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );

drop policy if exists kpi_entries_update on public.kpi_entries;
create policy kpi_entries_update on public.kpi_entries for update to authenticated
  using (
    public.has_role('ceo','hr')
    or (employee_id = public.my_employee_id() and status = 'pending')
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  )
  with check (
    public.has_role('ceo','hr')
    or employee_id = public.my_employee_id()
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );

drop policy if exists kpi_entries_delete on public.kpi_entries;
create policy kpi_entries_delete on public.kpi_entries for delete to authenticated
  using ( public.has_role('ceo','hr') or (employee_id = public.my_employee_id() and status = 'pending') );
