-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_041.sql
-- A break press as the first punch of the day means the person forgot
-- to check in. It is stored as a check-in with a note saying so, and
-- the review shows the note. Applies to punches from the device, the
-- app and manual entry; the two existing cases are corrected.
-- ADDITIVE ONLY. Run once, after 040.
-- =====================================================================

create or replace function public.first_break_is_checkin()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.employee_id is null or new.direction not in ('break_in','break_out') then return new; end if;
  if not exists (
    select 1 from public.attendance_punches q
     where q.employee_id = new.employee_id
       and (q.punch_time at time zone 'Africa/Cairo')::date = (new.punch_time at time zone 'Africa/Cairo')::date
       and q.punch_time < new.punch_time
       and q.id is distinct from new.id
  ) then
    new.note := trim(coalesce(new.note || ' · ', '') ||
      case new.direction when 'break_out' then 'Break-start pressed first, counted as check-in (no check-in that day)'
                         else 'Break-end pressed first, counted as check-in (no check-in that day)' end);
    new.direction := 'in';
  end if;
  return new;
end;
$fn$;
drop trigger if exists trg_first_break_is_checkin on public.attendance_punches;
create trigger trg_first_break_is_checkin before insert or update of direction, punch_time, employee_id on public.attendance_punches
  for each row execute function public.first_break_is_checkin();

-- correct the days already recorded that way
update public.attendance_punches p
   set direction = 'in',
       note = trim(coalesce(p.note || ' · ', '') || case p.direction when 'break_out' then 'Break-start pressed first, counted as check-in (no check-in that day)' else 'Break-end pressed first, counted as check-in (no check-in that day)' end)
 where p.direction in ('break_in','break_out')
   and not exists (select 1 from public.attendance_punches q
                    where q.employee_id = p.employee_id
                      and (q.punch_time at time zone 'Africa/Cairo')::date = (p.punch_time at time zone 'Africa/Cairo')::date
                      and q.punch_time < p.punch_time);
