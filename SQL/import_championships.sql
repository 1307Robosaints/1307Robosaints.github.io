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
  ('Burns ''27',   'Eastern States Exposition, West Springfield, MA', '2027-04-16', 'NECMP1', '2027necmp1', 'district_championship'),
  ('Newsom ''27',  'Eastern States Exposition, West Springfield, MA', '2027-04-16', 'NECMP2', '2027necmp2', 'district_championship'),

  -- 2026 FIRST Championship, Houston (Wed 4/29 - Sat 5/2, 2026). The overall event code
  -- (CMPTX) is where Einstein finals are recorded, so that row is named for Einstein rather
  -- than repeating "FIRST Championship" — the tier badge already says "Championship".
  ('Einstein ''26',    'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'CMPTX',      '2026cmptx',      'championship'),
  ('Archimedes ''26',  'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'ARCHIMEDES', '2026arc', 'championship'),
  ('Curie ''26',       'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'CURIE',      '2026cur',      'championship'),
  ('Daly ''26',        'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'DALY',       '2026dal',       'championship'),
  ('Galileo ''26',     'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'GALILEO',    '2026gal',    'championship'),
  ('Hopper ''26',      'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'HOPPER',     '2026hop',     'championship'),
  ('Johnson ''26',     'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'JOHNSON',    '2026joh',    'championship'),
  ('Milstein ''26',    'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'MILSTEIN',   '2026mil',   'championship'),
  ('Newton ''26',      'George R. Brown Convention Center, Houston, TX', '2026-05-01', 'NEWTON',     '2026new',     'championship'),

  -- 2027 FIRST Championship, Houston (Wed 4/28 - Sat 5/1, 2027)
  ('Einstein ''27',    'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'CMPTX',      '2027cmptx',      'championship'),
  ('Archimedes ''27',  'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'ARCHIMEDES', '2027arc', 'championship'),
  ('Curie ''27',       'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'CURIE',      '2027cur',      'championship'),
  ('Daly ''27',        'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'DALY',       '2027dal',       'championship'),
  ('Galileo ''27',     'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'GALILEO',    '2027gal',    'championship'),
  ('Hopper ''27',      'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'HOPPER',     '2027hop',     'championship'),
  ('Johnson ''27',     'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'JOHNSON',    '2027joh',    'championship'),
  ('Milstein ''27',    'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'MILSTEIN',   '2027mil',   'championship'),
  ('Newton ''27',      'George R. Brown Convention Center, Houston, TX', '2027-04-30', 'NEWTON',     '2027new',     'championship')
) as v(name, location, event_date, frc_event_code, tba_event_key, event_tier)
where not exists (
  select 1 from public.events e
  where e.name = v.name or e.frc_event_code = v.frc_event_code
);

-- One-off rename for rows already inserted under the old naming convention
-- (the tier badge next to the name already said "Championship"/"District
-- Champs", so repeating "FIRST Championship -" / "District Champs -" on the
-- name itself was redundant). Matched by frc_event_code so it's a no-op once
-- already renamed.
update public.events set name = 'Burns ''27'       where frc_event_code = 'NECMP1'     and event_tier = 'district_championship' and name <> 'Burns ''27';
update public.events set name = 'Newsom ''27'      where frc_event_code = 'NECMP2'     and event_tier = 'district_championship' and name <> 'Newsom ''27';
update public.events set name = 'Einstein ''26'    where frc_event_code = 'CMPTX'      and event_date = '2026-05-01' and name <> 'Einstein ''26';
update public.events set name = 'Archimedes ''26'  where frc_event_code = 'ARCHIMEDES' and event_date = '2026-05-01' and name <> 'Archimedes ''26';
update public.events set name = 'Curie ''26'       where frc_event_code = 'CURIE'      and event_date = '2026-05-01' and name <> 'Curie ''26';
update public.events set name = 'Daly ''26'        where frc_event_code = 'DALY'       and event_date = '2026-05-01' and name <> 'Daly ''26';
update public.events set name = 'Galileo ''26'     where frc_event_code = 'GALILEO'    and event_date = '2026-05-01' and name <> 'Galileo ''26';
update public.events set name = 'Hopper ''26'      where frc_event_code = 'HOPPER'     and event_date = '2026-05-01' and name <> 'Hopper ''26';
update public.events set name = 'Johnson ''26'     where frc_event_code = 'JOHNSON'    and event_date = '2026-05-01' and name <> 'Johnson ''26';
update public.events set name = 'Milstein ''26'    where frc_event_code = 'MILSTEIN'   and event_date = '2026-05-01' and name <> 'Milstein ''26';
update public.events set name = 'Newton ''26'      where frc_event_code = 'NEWTON'     and event_date = '2026-05-01' and name <> 'Newton ''26';
update public.events set name = 'Einstein ''27'    where frc_event_code = 'CMPTX'      and event_date = '2027-04-30' and name <> 'Einstein ''27';
update public.events set name = 'Archimedes ''27'  where frc_event_code = 'ARCHIMEDES' and event_date = '2027-04-30' and name <> 'Archimedes ''27';
update public.events set name = 'Curie ''27'       where frc_event_code = 'CURIE'      and event_date = '2027-04-30' and name <> 'Curie ''27';
update public.events set name = 'Daly ''27'        where frc_event_code = 'DALY'       and event_date = '2027-04-30' and name <> 'Daly ''27';
update public.events set name = 'Galileo ''27'     where frc_event_code = 'GALILEO'    and event_date = '2027-04-30' and name <> 'Galileo ''27';
update public.events set name = 'Hopper ''27'      where frc_event_code = 'HOPPER'     and event_date = '2027-04-30' and name <> 'Hopper ''27';
update public.events set name = 'Johnson ''27'     where frc_event_code = 'JOHNSON'    and event_date = '2027-04-30' and name <> 'Johnson ''27';
update public.events set name = 'Milstein ''27'    where frc_event_code = 'MILSTEIN'   and event_date = '2027-04-30' and name <> 'Milstein ''27';
update public.events set name = 'Newton ''27'      where frc_event_code = 'NEWTON'     and event_date = '2027-04-30' and name <> 'Newton ''27';


-- Check query
select name, location, event_date, frc_event_code, tba_event_key, event_tier
from public.events
where event_tier in ('district_championship','championship')
order by event_date, name;
