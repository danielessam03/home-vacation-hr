-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_033.sql
-- Leave history import from Excel (Leave -> Import / Export):
--   * import_key on leave_requests and leave_adjustments so re-uploading
--     the same sheet updates rows instead of duplicating them
--   * leave_imports log
-- ADDITIVE ONLY. Run once, after 032.
-- =====================================================================

alter table public.leave_requests    add column if not exists import_key text;
alter table public.leave_adjustments add column if not exists import_key text;
create unique index if not exists uq_leave_req_import on public.leave_requests(import_key);  -- full index: upsert on conflict needs it
create unique index if not exists uq_leave_adj_import on public.leave_adjustments(import_key);

create table if not exists public.leave_imports (
  id            uuid primary key default gen_random_uuid(),
  layout        text not null check (layout in ('list','totals')),
  file_name     text,
  rows_total    int not null default 0,
  rows_imported int not null default 0,
  rows_skipped  int not null default 0,
  created_by    uuid references public.app_users(id),
  created_at    timestamptz not null default now()
);
alter table public.leave_imports enable row level security;
drop policy if exists leave_imports_rw on public.leave_imports;
create policy leave_imports_rw on public.leave_imports for all to authenticated
  using ( public.has_role('ceo','hr') ) with check ( public.has_role('ceo','hr') );
