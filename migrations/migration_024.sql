-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_024.sql
-- HR and the CEO may delete any leave request, including approved ones
-- (the balance is recalculated from what remains). A make-up day that
-- pointed at a deleted leave keeps its record but loses the link.
-- ADDITIVE ONLY. Run once, after 023.
-- =====================================================================

drop policy if exists leave_req_delete on public.leave_requests;
create policy leave_req_delete on public.leave_requests for delete to authenticated
  using ( public.has_role('ceo','hr') );

alter table public.leave_makeups drop constraint if exists leave_makeups_leave_request_id_fkey;
alter table public.leave_makeups add constraint leave_makeups_leave_request_id_fkey
  foreign key (leave_request_id) references public.leave_requests(id) on delete set null;
