-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_047.sql
-- Missing punch (checked in, never checked out): once the day is over it
-- needs a decision. The decision is one attendance_exceptions row of
-- kind 'missing_punch' per employee-day:
--   status 'approved'  = excused, no deduction
--   status 'rejected'  = action taken; penalty_kind / penalty_value say what
--                        ('none' warning only, 'hours', 'day_fraction')
-- Payroll deducts the penalty and counts the days still undecided.
-- ADDITIVE ONLY. Run once, after 046.
-- =====================================================================

alter table public.attendance_exceptions drop constraint if exists attendance_exceptions_kind_check;
alter table public.attendance_exceptions add constraint attendance_exceptions_kind_check
  check (kind in ('late','break','early_leave','missing_punch'));
alter table public.attendance_exceptions add column if not exists penalty_kind  text;
alter table public.attendance_exceptions add column if not exists penalty_value numeric(6,2);
alter table public.attendance_exceptions drop constraint if exists attendance_exceptions_penalty_check;
alter table public.attendance_exceptions add constraint attendance_exceptions_penalty_check
  check (penalty_kind is null or penalty_kind in ('none','hours','day_fraction'));
create unique index if not exists uq_att_exc_missing_day on public.attendance_exceptions(employee_id, exc_date) where kind = 'missing_punch';

alter table public.payroll_items add column if not exists missing_days      int not null default 0;
alter table public.payroll_items add column if not exists missing_deduction numeric(12,2) not null default 0;
alter table public.payroll_items add column if not exists missing_detail    jsonb not null default '[]'::jsonb;
alter table public.payroll_items add column if not exists missing_pending   int not null default 0;

notify pgrst, 'reload schema';
