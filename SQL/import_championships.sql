-- =====================================================================
-- 1307scout: DATA IMPORT ONLY — on-season championship events
--
-- Row-only changes to public.events. No schema/policy changes — but it
-- DOES set the event_tier column added by rebuild_all.sql, so run that
-- file first if you haven't already (this import is safe to re-run on
-- its own after that).
--
-- Adds the two on-season championship levels above a regular district
-- qualifier, each tagged with the event_tier that makes
-- team_official_ratings() weight their results more heavily
-- (event_tier_weight(), in rebuild_all.sql):
--   - The 2027 New England District Championship (district_championship,
--     1.5x) — the 2026 one was already added by import_2026_ne_events.sql.
--   - The 2026 and 2027 FIRST Championship ("Worlds") in Houston
--     (championship, 2.0x) — one row for the overall event (Einstein
--     finals are recorded under this code) plus one per division, since
--     FRC Events/TBA report qualification and playoff matches per
--     division, not under the overall event code.
--
-- Source: frc-events.firstinspires.org/2027/district/NE (NE champs) and
-- frc-events.firstinspires.org/{2026,2027}/CMPTX (FIRST Championship and
-- its 8 divisions), read 2026-11-06.
--
-- event_date follows this project's usual rule: the day before the
-- event's last day.
-- =====================================================================

insert into public.events (name, location, event_date, frc_event_code, tba_event_key, event_tier)
select v.name, v.location, v.event_date::date, v.frc_event_code, v.tba_event_key, v.event_tier
from (values
  -- 2027 New England District Championship (Wed 4/14 - Sat 4/17, 2027)
  ('District Champs - Burns ''27',   'Eastern States Exposition, West Springfield, MA', '2027-04-16', 'NECMP1', '2027necmp1', 'district_championship'),
  ('District Champs - Newsom ''27',  'Eastern States Exposition, West Springfield, MA', '2027-04-16', 'NECMP2', '2027necmp2', 'district_championship'),

  -- 2026 FIRST Championship, Houston (Wed 4/29 - Sat 5/2, 2026)
  ('FIRST Championship ''26',            'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'CMPTX',      '2026cmptx',      'championship'),
  ('FIRST Championship - Archimedes ''26','George R. Brown Convention Center, Houston, TX', '2026-05-01', 'ARCHIMEDES', '2026archimedes', 'championship'),
  ('FIRST Championship - Curie ''26',     'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'CURIE',      '2026curie',      'championship'),
  ('FIRST Championship - Daly ''26',      'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'DALY',       '2026daly',       'championship'),
  ('FIRST Championship - Galileo ''26',   'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'GALILEO',    '2026galileo',    'championship'),
  ('FIRST Championship - Hopper ''26',    'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'HOPPER',     '2026hopper',     'championship'),
  ('FIRST Championship - Johnson ''26',   'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'JOHNSON',    '2026johnson',    'championship'),
  ('FIRST Championship - Milstein ''26',  'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'MILSTEIN',   '2026milstein',   'championship'),
  ('FIRST Championship - Newton ''26',    'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'NEWTON',     '2026newton',     'championship'),

  -- 2027 FIRST Championship, Houston (Wed 4/28 - Sat 5/1, 2027)
  ('FIRST Championship ''27',            'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'CMPTX',      '2027cmptx',      'championship'),
  ('FIRST Championship - Archimedes ''27','George R. Brown Convention Center, Houston, TX', '2027-04-30', 'ARCHIMEDES', '2027archimedes', 'championship'),
  ('FIRST Championship - Curie ''27',     'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'CURIE',      '2027curie',      'championship'),
  ('FIRST Championship - Daly ''27',      'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'DALY',       '2027daly',       'championship'),
  ('FIRST Championship - Galileo ''27',   'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'GALILEO',    '2027galileo',    'championship'),
  ('FIRST Championship - Hopper ''27',    'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'HOPPER',     '2027hopper',     'championship'),
  ('FIRST Championship - Johnson ''27',   'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'JOHNSON',    '2027johnson',    'championship'),
  ('FIRST Championship - Milstein ''27',  'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'MILSTEIN',   '2027milstein',   'championship'),
  ('FIRST Championship - Newton ''27',    'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'NEWTON',     '2027newton',     'championship')
) as v(name, location, event_date, frc_event_code, tba_event_key, event_tier)
where not exists (
  select 1 from public.events e
  where e.name = v.name or e.frc_event_code = v.frc_event_code
);


-- Check query
select name, location, event_date, frc_event_code, tba_event_key, event_tier
from public.events
where event_tier in ('district_championship','championship')
order by event_date, name;
