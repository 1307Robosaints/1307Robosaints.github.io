-- =====================================================================
-- 1307scout: DATA IMPORT ONLY — link "Battle of the Gay/Girls Behind the
--            Glass '26" to its real FRC/TBA event code.
--
-- Row-only, no schema/policy changes. Safe to re-run.
--
-- This off-season event is "Battle Of the Bay" at Prospect Mountain High
-- School, Alton, NH, Saturday Nov 7, 2026 — an exact match by venue and
-- date to the event already in the table. Confirmed at
-- https://frc-events.firstinspires.org/2026/NHALT (code NHALT; the page
-- explicitly marks it an Off-Season event). TBA key follows the standard
-- <year><lowercase code> convention used throughout this project.
-- =====================================================================
update public.events
set frc_event_code = 'NHALT',
    tba_event_key   = '2026nhalt'
where name = 'Battle of the Gay/Girls Behind the Glass ''26'
  and frc_event_code is null
  and tba_event_key is null;
