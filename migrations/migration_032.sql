-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_032.sql
-- Leave entitlement rule (Settings -> Work week -> Leave entitlement):
--   1 rest day a week  -> 21 annual days
--   2 rest days a week -> 14 annual days
--   hired in the second half of the year -> 8 days for that first year
--   casual leave: 1 day for everyone (taken from the annual balance)
-- Each employee can be overridden (annual_days_override, new
-- casual_days_override) from the employee card.
-- ADDITIVE ONLY. Run once, after 031.
-- =====================================================================

alter table public.employees add column if not exists casual_days_override numeric(5,1);

insert into public.app_settings (key, value) values ('leave_policy', '{
  "annual_one_rest_day": 21,
  "annual_two_rest_days": 14,
  "annual_second_half_hire": 8,
  "casual_days": 1
}'::jsonb)
on conflict (key) do nothing;

update public.leave_types set max_days_per_year = 1 where code = 'casual';
