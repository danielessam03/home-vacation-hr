-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_051.sql
-- Breaks started on the fingerprint machine can be ended online and the
-- other way round:
--   * machine break-start (break_out) + online "End break" -> the app
--     inserts a break_in punch (source 'web'); the pair counts as one
--     device break, as before.
--   * online break (work_sessions.status = 'break') + machine break-end
--     (break_in punch) -> this trigger closes the app break, so the
--     person is back at work without a selfie. A lone break_in punch is
--     ignored by the device-break pairing, so nothing is counted twice.
-- ADDITIVE ONLY. Run once, after 050.
-- =====================================================================

create or replace function public.punch_closes_app_break()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare
  s public.work_sessions%rowtype;
  v_extra int;
begin
  if new.employee_id is null or new.direction <> 'break_in' then return new; end if;
  select * into s from public.work_sessions w
   where w.employee_id = new.employee_id and w.status = 'break' and w.break_started_at is not null
   order by w.started_at desc limit 1;
  if s.id is null then return new; end if;
  v_extra := greatest(0, extract(epoch from (new.punch_time - s.break_started_at)))::int;
  update public.work_sessions
     set status = 'working', break_started_at = null, break_seconds = coalesce(break_seconds, 0) + v_extra, last_activity_at = new.punch_time
   where id = s.id;
  insert into public.session_events (session_id, employee_id, kind, meta)
  values (s.id, new.employee_id, 'break_end', jsonb_build_object('reason', case when new.source = 'web' then 'online' else 'device' end, 'punch_id', new.id));
  return new;
exception when others then
  return new;   -- a punch must never fail because of the live session
end;
$fn$;
drop trigger if exists trg_punch_closes_app_break on public.attendance_punches;
create trigger trg_punch_closes_app_break after insert on public.attendance_punches
  for each row execute function public.punch_closes_app_break();
