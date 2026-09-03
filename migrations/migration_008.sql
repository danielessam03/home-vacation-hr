-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_008.sql
-- Module 6: loans & salary advances with installment schedules,
--           automatic deduction in payroll, manual/early settlement.
--
-- ADDITIVE ONLY. Run once, after 007.
-- =====================================================================

create table if not exists public.loans (
  id                 uuid primary key default gen_random_uuid(),
  employee_id        uuid not null references public.employees(id),
  loan_type          text not null default 'advance' check (loan_type in ('loan','advance')),
  principal          numeric(14,2) not null check (principal > 0),
  installments_count int not null default 1 check (installments_count > 0),
  installment_amount numeric(14,2) not null check (installment_amount > 0),
  start_year         int not null,
  start_month        int not null check (start_month between 1 and 12),
  paid_total         numeric(14,2) not null default 0,   -- kept in sync by trigger
  status             text not null default 'active' check (status in ('active','settled','cancelled')),
  reason             text,
  created_by         uuid references public.app_users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists idx_loans_employee on public.loans(employee_id, status);

drop trigger if exists trg_loans_touch on public.loans;
create trigger trg_loans_touch before update on public.loans
  for each row execute function public.touch_updated_at();

create table if not exists public.loan_payments (
  id              uuid primary key default gen_random_uuid(),
  loan_id         uuid not null references public.loans(id) on delete cascade,
  employee_id     uuid not null references public.employees(id),
  payroll_item_id uuid references public.payroll_items(id),
  year            int not null,
  month           int not null check (month between 1 and 12),
  amount          numeric(14,2) not null check (amount > 0),
  kind            text not null default 'payroll' check (kind in ('payroll','manual')),
  note            text,
  created_by      uuid references public.app_users(id),
  created_at      timestamptz not null default now()
);
create index if not exists idx_loan_payments_loan on public.loan_payments(loan_id);
-- a payroll item can pay a given loan only once
create unique index if not exists uq_loan_payment_item
  on public.loan_payments(loan_id, payroll_item_id) where payroll_item_id is not null;

-- keep loans.paid_total and status in sync with payments, automatically
create or replace function public.sync_loan_totals()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  lid   uuid := coalesce(new.loan_id, old.loan_id);
  total numeric;
begin
  select coalesce(sum(amount), 0) into total from public.loan_payments where loan_id = lid;
  update public.loans
     set paid_total = total,
         status = case when status = 'cancelled' then 'cancelled'
                       when total >= principal then 'settled'
                       else 'active' end
   where id = lid;
  return coalesce(new, old);
end;
$fn$;

drop trigger if exists trg_loan_payments_sync on public.loan_payments;
create trigger trg_loan_payments_sync after insert or update or delete on public.loan_payments
  for each row execute function public.sync_loan_totals();

-- payroll items carry the loan deduction and which loans it covers
alter table public.payroll_items add column if not exists loan_deduction numeric(14,2) not null default 0;
alter table public.payroll_items add column if not exists loan_details jsonb not null default '[]'::jsonb;

-- ---------------------------------------------------------------------
-- RLS: employee sees own; ceo/hr/accountant manage
-- ---------------------------------------------------------------------
alter table public.loans         enable row level security;
alter table public.loan_payments enable row level security;

drop policy if exists loans_select on public.loans;
create policy loans_select on public.loans for select to authenticated
  using ( public.has_role('ceo','hr','accountant') or employee_id = public.my_employee_id() );
drop policy if exists loans_write on public.loans;
create policy loans_write on public.loans for all to authenticated
  using ( public.has_role('ceo','hr','accountant') ) with check ( public.has_role('ceo','hr','accountant') );

drop policy if exists loan_payments_select on public.loan_payments;
create policy loan_payments_select on public.loan_payments for select to authenticated
  using ( public.has_role('ceo','hr','accountant') or employee_id = public.my_employee_id() );
drop policy if exists loan_payments_write on public.loan_payments;
create policy loan_payments_write on public.loan_payments for all to authenticated
  using ( public.has_role('ceo','hr','accountant') ) with check ( public.has_role('ceo','hr','accountant') );
