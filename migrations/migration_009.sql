-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_009.sql
-- Module 7: compliance -- filing calendar, database-level audit
--           triggers on every sensitive table, employer registration
--           numbers for NOSI/tax forms.
--
-- ADDITIVE ONLY. Run once, after 008.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Employer registration numbers used on the NOSI / tax forms
-- ---------------------------------------------------------------------
update public.app_settings
   set value = value || jsonb_build_object(
     'nosi_employer_no', coalesce(value->>'nosi_employer_no', ''),
     'tax_office',       coalesce(value->>'tax_office', ''),
     'commercial_reg',   coalesce(value->>'commercial_reg', ''),
     'address',          coalesce(value->>'address', ''))
 where key = 'company';

-- ---------------------------------------------------------------------
-- 2. Database-level audit: catches every change even if it bypasses the
--    app (SQL editor, edge functions, future integrations).
--    source = 'db' distinguishes these from the app's semantic entries.
-- ---------------------------------------------------------------------
alter table public.audit_log add column if not exists source text not null default 'app';
create index if not exists idx_audit_source on public.audit_log(source, created_at desc);

create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  actor uuid := auth.uid();
  actor_mail text;
  actor_rl text;
  rid text;
begin
  if actor is not null then
    select email, role into actor_mail, actor_rl from public.app_users where id = actor;
  end if;
  rid := coalesce(to_jsonb(coalesce(new, old))->>'id', to_jsonb(coalesce(new, old))->>'key');
  insert into public.audit_log (actor_id, actor_email, actor_role, action, entity, entity_id, before_data, after_data, source)
  values (
    actor, actor_mail, actor_rl,
    lower(tg_op), tg_table_name, rid,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,
    'db'
  );
  return coalesce(new, old);
end;
$fn$;

do $trg$
declare tbl text;
begin
  foreach tbl in array array[
    'app_users','employees','employee_documents','app_settings','tax_brackets','tax_settings',
    'insurance_rates','attendance_locks','leave_requests','leave_adjustments',
    'payroll_runs','payroll_items','loans','loan_payments','job_roles'
  ] loop
    execute format('drop trigger if exists trg_audit_%s on public.%I', tbl, tbl);
    execute format('create trigger trg_audit_%s after insert or update or delete on public.%I
                    for each row execute function public.audit_row_change()', tbl, tbl);
  end loop;
end;
$trg$;

-- the app-level audit insert policy stays; db-level rows are written by the
-- SECURITY DEFINER trigger and need no policy.

-- ---------------------------------------------------------------------
-- 3. Filing calendar
-- ---------------------------------------------------------------------
create table if not exists public.compliance_tasks (
  id          uuid primary key default gen_random_uuid(),
  title_en    text not null,
  title_ar    text not null,
  category    text not null default 'nosi' check (category in ('nosi','tax','labor','other')),
  due_date    date not null,
  recurrence  text not null default 'once' check (recurrence in ('once','monthly','quarterly','annual')),
  status      text not null default 'open' check (status in ('open','done')),
  notes       text,
  done_by     uuid references public.app_users(id),
  done_at     timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists idx_compliance_due on public.compliance_tasks(status, due_date);

alter table public.compliance_tasks enable row level security;
drop policy if exists compliance_all on public.compliance_tasks;
create policy compliance_all on public.compliance_tasks for all to authenticated
  using ( public.has_role('ceo','hr','accountant') ) with check ( public.has_role('ceo','hr','accountant') );

-- Seed the standard Egyptian filing cycle (next occurrences). Dates are
-- customary deadlines -- confirm with your accountant and edit freely.
insert into public.compliance_tasks (title_en, title_ar, category, due_date, recurrence, notes)
select * from (values
  ('Monthly social insurance contributions', 'سداد اشتراكات التأمينات الشهرية', 'nosi',
   (date_trunc('month', current_date) + interval '1 month' + interval '14 days')::date, 'monthly',
   'Due within the first 15 days of the following month.'),
  ('Monthly salary tax remittance', 'توريد ضريبة المرتبات الشهرية', 'tax',
   (date_trunc('month', current_date) + interval '1 month' + interval '14 days')::date, 'monthly',
   'Withheld salary tax for the previous month, within 15 days.'),
  ('Quarterly salary tax return (Form 4)', 'الإقرار الربع سنوي لضريبة المرتبات (نموذج 4)', 'tax',
   (date_trunc('quarter', current_date) + interval '4 months' - interval '1 day')::date, 'quarterly',
   'Within one month after the end of each quarter.'),
  ('Annual salary tax reconciliation', 'التسوية السنوية لضريبة المرتبات', 'tax',
   make_date(extract(year from current_date)::int + 1, 1, 31), 'annual',
   'Annual settlement for the previous year, by end of January.'),
  ('NOSI annual wages declaration (Form 2)', 'بيان الأجور السنوي للتأمينات (استمارة 2)', 'nosi',
   make_date(extract(year from current_date)::int + 1, 1, 31), 'annual',
   'Wages of all insured employees as at 1 January.')
) as v(title_en, title_ar, category, due_date, recurrence, notes)
where not exists (select 1 from public.compliance_tasks);
