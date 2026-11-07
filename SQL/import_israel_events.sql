-- =====================================================================
-- 1307scout: DATA IMPORT ONLY — FIRST Israel events and Israeli teams
--
-- Row-only changes to public.events and public.team_info. No schema or
-- policy changes, but it sets event_tier, so run rebuild_all.sql first.
-- Safe to re-run: every statement checks before writing.
--
-- Source: frc-events.firstinspires.org/{2026,2027}/district/ISR, every
-- Israeli team's page, and each event's own page, read 2026-11-07.
-- Competing-team lists on the event pages are what count here. Team
-- pages still show tabs left over from the original 2026 schedule.
--
-- Scope: the 2026 and 2027 seasons, the same seasons as the other
-- imports. Israeli teams attended no event outside Israel in 2026 except
-- the FIRST Championship, whose rows come from import_championships.sql
-- (12 teams: Curie 1, Daly 1, Galileo 2, Johnson 1, Milstein 3, Newton 4).
-- FIRST lists no Israeli off-season event for either year.
--
-- 2026 ISDE3 and ISDE4 are left out on purpose. FIRST marks them
-- Complete (Mar 15-19, Hadera), but they have no matches and no rankings:
-- they were never played. ISDE1, ISDE2, and ISCMP were rescheduled to
-- June/July and did run, so their dates here are the makeup dates.
--
-- TBA keys follow the usual <year><lowercase code> rule. TBA couldn't be
-- read directly, so a wrong key would show up as a sync error in the
-- Staff Portal. FRC codes were confirmed on FIRST's site.
--
-- event_date follows this project's usual rule: the day before the
-- event's last day.
--
-- This adds the events only. Match results arrive when official-sync
-- runs, from Resync All in the Staff Portal.
-- =====================================================================


-- =====================================================================
-- 1. Events
--    Matched on tba_event_key, not frc_event_code: FIRST reuses codes
--    every year, so ISDE1 '26 would otherwise block ISDE1 '27.
-- =====================================================================
insert into public.events (name, location, event_date, frc_event_code, tba_event_key, event_tier)
select v.name, v.location, v.event_date::date, v.frc_event_code, v.tba_event_key, v.event_tier
from (values
  -- Sun 6/28 - Mon 6/29, 2026
  ('Israel District 1 ''26', 'Arena Natanya, Natanya, Israel', '2026-06-28', 'ISDE1', '2026isde1', 'qualifier'),
  -- Tue 6/30 - Wed 7/1, 2026
  ('Israel District 2 ''26', 'Arena Natanya, Natanya, Israel', '2026-06-30', 'ISDE2', '2026isde2', 'qualifier'),
  -- Mon 7/6 - Wed 7/8, 2026
  ('Israel Championship ''26', 'Enerbox, Hadera, Israel', '2026-07-07', 'ISCMP', '2026iscmp', 'district_championship'),
  -- Sun 2/28 - Tue 3/2, 2027
  ('Israel District 1 ''27', 'Shlomo Group Arena, Tel Aviv-Yafo, Israel', '2027-03-01', 'ISDE1', '2027isde1', 'qualifier'),
  -- Tue 3/2 - Thu 3/4, 2027
  ('Israel District 2 ''27', 'Shlomo Group Arena, Tel Aviv-Yafo, Israel', '2027-03-03', 'ISDE2', '2027isde2', 'qualifier'),
  -- Sat 3/6 - Mon 3/8, 2027
  ('Israel District 3 ''27', 'Shlomo Group Arena, Tel Aviv-Yafo, Israel', '2027-03-07', 'ISDE3', '2027isde3', 'qualifier'),
  -- Sun 3/14 - Tue 3/16, 2027
  ('Israel District 4 ''27', 'Enerbox, Hadera, Israel', '2027-03-15', 'ISDE4', '2027isde4', 'qualifier'),
  -- Tue 3/16 - Thu 3/18, 2027
  ('Israel District 5 ''27', 'Enerbox, Hadera, Israel', '2027-03-17', 'ISDE5', '2027isde5', 'qualifier'),
  -- Sun 3/28 - Wed 3/31, 2027
  ('Israel Championship ''27', 'Pais Arena, Jerusalem, Israel', '2027-03-30', 'ISCMP', '2027iscmp', 'district_championship')
) as v(name, location, event_date, frc_event_code, tba_event_key, event_tier)
where not exists (
  select 1 from public.events e
  where e.name = v.name or e.tba_event_key = v.tba_event_key
);


-- =====================================================================
-- 2. Team names
--    Every Israeli team registered for 2026 or 2027, using the newest
--    name FIRST lists. Rows that already exist are left alone, so this
--    never overwrites a name or logo staff set in the portal.
-- =====================================================================
insert into public.team_info (team_number, team_name)
values
  (1574, 'MisCar'),
  (1576, 'Voltrix'),
  (1577, 'Steampunk'),
  (1580, 'The Blue Monkeys'),
  (1690, 'Orbit'),
  (1937, 'Elysium'),
  (1942, 'Cinderella Tel-Nof'),
  (1943, 'Neat Team'),
  (1954, 'ElectroBunny'),
  (2096, 'RoboActive'),
  (2212, 'The Spikes'),
  (2230, 'General Angels'),
  (2231, 'OnyxTronix'),
  (2630, 'Thunderbolts'),
  (2679, 'Atlantis'),
  (3065, 'Jatt High School'),
  (3075, 'Ha-Dream Team'),
  (3083, 'Artemis'),
  (3211, 'The Y Team'),
  (3316, 'D-Bug'),
  (3339, 'BumbleB'),
  (3388, 'Flash in memory of Margarita Gusak'),
  (3835, 'Vulcan'),
  (4319, 'Ladies FIRST'),
  (4320, 'The Joker'),
  (4338, 'Falcons'),
  (4416, 'Skynet'),
  (4586, 'PRIMO'),
  (4590, 'GreenBlitz'),
  (4661, 'Cypher'),
  (4744, 'Da Vinci'),
  (5135, 'Black Unicorns'),
  (5291, 'Emperius'),
  (5554, 'The Poros Robotics'),
  (5614, 'Team Sycamore'),
  (5635, 'Demacia'),
  (5654, 'Phoenix'),
  (5715, 'DRC'),
  (5928, 'MetalBoost'),
  (5951, 'Makers Assemble'),
  (5987, 'Galaxia in memory of David Zohar'),
  (5990, 'TRIGON'),
  (6104, 'Desert Eagles in memory of Yehonatan Maimon'),
  (6168, 'alzahrawi 6168'),
  (6230, 'Team Koi'),
  (6738, 'Excalibur'),
  (6740, 'G3 - Glue Gun & Glitter'),
  (7039, '❌⭕'),
  (7067, 'Team Streak'),
  (7112, 'EverGreen'),
  (7177, 'Turismo'),
  (7845, '8BIT'),
  (8175, 'Piece of Mind'),
  (8223, 'Mariners'),
  (9303, 'PORTAL'),
  (9304, 'legend''s'),
  (9738, 'Ionic Bond'),
  (9739, 'Firefly'),
  (9740, 'CANBus in memory of Roney Tal'),
  (10139, 'Tsunami'),
  (10695, 'Galileo'),
  (10935, 'Krono'),
  (10986, 'Negev Dominion'),
  (11070, 'RoboRex'),
  (11329, 'G-Force'),
  (11332, 'Sunrise'),
  (11390, 'Habsor'),
  (11471, 'Neon'),
  (11478, 'Nexus'),
  (11480, 'EXODUS'),
  (11785, 'Orion'),
  (11905, 'Pulse'),
  (12234, 'Polaris')
on conflict (team_number) do nothing;


-- =====================================================================
-- 3. Check queries — run after the above.
--    The first should list 9 events. The second should show 73.
-- =====================================================================
select name, location, event_date, frc_event_code, tba_event_key, event_tier
from public.events
where tba_event_key ~ '^202[67]is(de[0-9]|cmp)$'
order by event_date;

select count(*) as israeli_teams_in_team_info
from public.team_info
where team_number in (1574, 1576, 1577, 1580, 1690, 1937, 1942, 1943, 1954, 2096, 2212, 2230, 2231, 2630, 2679, 3065, 3075, 3083, 3211, 3316, 3339, 3388, 3835, 4319, 4320, 4338, 4416, 4586, 4590, 4661, 4744, 5135, 5291, 5554, 5614, 5635, 5654, 5715, 5928, 5951, 5987, 5990, 6104, 6168, 6230, 6738, 6740, 7039, 7067, 7112, 7177, 7845, 8175, 8223, 9303, 9304, 9738, 9739, 9740, 10139, 10695, 10935, 10986, 11070, 11329, 11332, 11390, 11471, 11478, 11480, 11785, 11905, 12234);
