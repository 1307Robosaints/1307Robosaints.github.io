-- =====================================================================
-- 1307scout: DATA FIX ONLY — TBA keys for six 2026 NE off-season events
--
-- Row-only changes to public.events. Safe to re-run: each update only
-- matches the old, wrong key, so a second run changes nothing.
--
-- import_ne_offseason_2026.sql built these TBA keys as year + FRC code,
-- but TBA names these off-season events differently, so their TBA sync
-- failed. Correct keys from TBA's 2026 event list (each one's
-- first_event_code matches the FRC code below), read 2026-11-07.
--
-- After running, resync these events in the Staff Portal.
-- =====================================================================

update public.events e
set tba_event_key = v.new_key
from (values
  ('MAWOR1', '2026mawor1', '2026bc'),     -- BattleCry at WPI 1
  ('MAWOR2', '2026mawor2', '2026bc2'),    -- BattleCry at WPI 2
  ('CTWOL',  '2026ctwol',  '2026wiwi'),   -- Where is Wolcott Invitational
  ('MABIL1', '2026mabil1', '2026matb'),   -- New England Robotics Derby
  ('NHMER',  '2026nhmer',  '2026nhmm'),   -- Mayhem in Merrimack
  ('NHMAN',  '2026nhman',  '2026nhrr')    -- RiverRage 29
) as v(frc_code, old_key, new_key)
where e.frc_event_code = v.frc_code
  and e.tba_event_key  = v.old_key;

-- Check query
select name, frc_event_code, tba_event_key
from public.events
where frc_event_code in ('MAWOR1','MAWOR2','CTWOL','MABIL1','NHMER','NHMAN')
order by event_date;
