-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_036.sql
-- A manager may record an accepted late / early / break note for a
-- member of their own team straight from the attendance review (HR and
-- the CEO already could for anyone).
-- ADDITIVE ONLY. Run once, after 035.
-- =====================================================================
drop policy if exists att_exc_insert on public.attendance_exceptions;
create policy att_exc_insert on public.attendance_exceptions for insert to authenticated
  with check (
    public.has_role('ceo','hr')
    or (employee_id = public.my_employee_id() and exc_date >= current_date and status = 'pending')
    or employee_id in (select id from public.employees where manager_id = public.my_employee_id())
  );
