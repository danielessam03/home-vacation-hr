-- =====================================================================
-- Home Vacation HR & Payroll  --  migration_062.sql
-- Personal-car trips: fuel compensation (Daniel, 2026-11-04)
--   "linked to the daily rate of benzine 92 in Egypt:
--    rate of benzine 92 × kms of the trip ÷ 7   (most cars use 7 L / 100 km)"
--   app_settings.fuel_policy = { fuel, divisor, prices: [{from, price}] }
--     prices  benzine 92 in EGP per litre with the date each price took
--             effect (HR adds a line whenever the government changes it;
--             a trip uses the price in force on its day)
--     divisor 7 by Daniel's rule; the app shows the amount on every closed
--             personal-car trip and the month totals (My HR, Attendance →
--             Trips). Edited in Attendance → Rules.
-- ADDITIVE ONLY. Safe to re-run. Run after 061.
-- =====================================================================
insert into public.app_settings (key, value) values
  ('fuel_policy', jsonb_build_object(
     'fuel', 'benzine_92',
     'divisor', 7,
     'prices', jsonb_build_array(jsonb_build_object('from', '2025-10-17', 'price', 19.25),    -- official prices: 19.25 from 17 Oct 2025,
                                 jsonb_build_object('from', '2026-03-10', 'price', 22.25))    -- 22.25 from 10 Mar 2026; HR adds the next change
   ))
on conflict (key) do nothing;
notify pgrst, 'reload schema';
