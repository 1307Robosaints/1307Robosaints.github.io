-- =====================================================================
-- 1307scout: DATA IMPORT ONLY — 2026 NE FIRST District events,
--            + FRC/TBA codes for already-entered 2027 events
--
-- This file touches ROWS in public.events only. It does not create or
-- alter any table, policy, function, or storage object — nothing here
-- changes the schema set up by rebuild_all.sql. Safe to re-run: every
-- statement checks before writing, so running this twice does nothing
-- the second time.
--
-- Source: https://frc-events.firstinspires.org/2026/district/NE and the
-- 2026 team/event detail pages under the same site, read 2026-11-06.
--
-- Section 1 inserts the 2026 NE District season (12 regular events +
-- both district championship divisions) using this project's naming
-- convention ("<Short name> '<YY>"), matched against what's already in
-- frc-events.firstinspires.org/2026/team/1307 and the per-event pages.
--
-- Section 2 sets frc_event_code / tba_event_key on the 2027 events that
-- were already sitting in the table unlinked: Minuteman, North Shore,
-- Granite State, Western NE, URI, UHart, UNH, UML, UVM, WPI, Waterbury,
-- and Pine Tree (all '27), matched by exact event name. Every one of
-- these was cross-checked against the official 2027 NE District schedule
-- by date (frc-events.firstinspires.org/2027/district/NE) and matched
-- exactly. 'Testing', 'Governor's Cup '26' (already linked), and 'Battle
-- of the Gay/Girls Behind the Glass '26' (an off-season event with no
-- FRC/TBA listing) are intentionally left untouched. No 2027 District
-- Championship row exists yet, so none is added here either.
--
-- event_date is a single day (the column has no event-end date), chosen
-- the same way the existing 2027 rows were: the day before the event's
-- last day (i.e. the Saturday of a Fri-Sun event, the last qualification
-- day before eliminations/alliance selection).
-- =====================================================================


-- =====================================================================
-- 1. 2026 NE FIRST District season
-- =====================================================================
insert into public.events (name, location, event_date, frc_event_code, tba_event_key)
select v.name, v.location, v.event_date::date, v.frc_event_code, v.tba_event_key
from (values
  ('Minuteman ''26',       'Billerica Memorial High School, Billerica, MA', '2026-03-07', 'MABIL',  '2026mabil'),
  ('Pine Tree ''26',       'Falmouth High School, Falmouth, ME',            '2026-03-07', 'MEFAL',  '2026mefal'),
  ('Granite State ''26',   'Bedford High School, Bedford, NH',              '2026-03-14', 'NHBED',  '2026nhbed'),
  ('North Shore ''26',     'Reading Memorial High School, Reading, MA',     '2026-03-14', 'MAREA',  '2026marea'),
  ('Western NE ''26',      'Western New England University, Springfield, MA','2026-03-14','MAWNE',  '2026mawne'),
  ('URI ''26',             'Keaney Gym, Kingston, RI',                      '2026-03-20', 'RIKIN',  '2026rikin'),
  ('Waterbury ''26',       'Wilby High School, Waterbury, CT',              '2026-03-21', 'CTWAT',  '2026ctwat'),
  ('UHart ''26',           'Hartford Public High School, Hartford, CT',     '2026-03-28', 'CTHAR',  '2026cthar'),
  ('UNH ''26',             'Whittemore Center Arena, Durham, NH',           '2026-03-28', 'NHDUR',  '2026nhdur'),
  ('Greater Boston ''26',  'Revere High School, Revere, MA',                '2026-03-28', 'MABOS',  '2026mabos'),
  ('UVM ''26',             'Patrick Gym, Burlington, VT',                   '2026-04-03', 'VTBUR',  '2026vtbur'),
  ('WPI ''26',             'Harrington Auditorium, Worcester, MA',          '2026-04-04', 'MAWOR',  '2026mawor'),
  ('District Champs - Burns ''26',  'Eastern States Exposition, West Springfield, MA', '2026-04-17', 'NECMP1', '2026necmp1'),
  ('District Champs - Newsom ''26', 'Eastern States Exposition, West Springfield, MA', '2026-04-17', 'NECMP2', '2026necmp2')
) as v(name, location, event_date, frc_event_code, tba_event_key)
where not exists (
  select 1 from public.events e
  where e.name = v.name or e.frc_event_code = v.frc_event_code
);


-- =====================================================================
-- 2. FRC/TBA codes for 2027 events already in the table
--    Only fills in rows that don't already have a code, so this never
--    overwrites a value staff already set by hand in the portal.
-- =====================================================================
update public.events e
set frc_event_code = v.frc_event_code,
    tba_event_key   = v.tba_event_key
from (values
  ('Minuteman ''27',     'MABIL', '2027mabil'),
  ('North Shore ''27',   'MAREA', '2027marea'),
  ('Granite State ''27', 'NHBED', '2027nhbed'),
  ('Western NE ''27',    'MAWNE', '2027mawne'),
  ('URI ''27',           'RIKIN', '2027rikin'),
  ('UHart ''27',         'CTHAR', '2027cthar'),
  ('UNH ''27',           'NHDUR', '2027nhdur'),
  ('UML ''27',           'MALOW', '2027malow'),
  ('UVM ''27',           'VTBUR', '2027vtbur'),
  ('WPI ''27',           'MAWOR', '2027mawor'),
  ('Waterbury ''27',     'CTWAT', '2027ctwat'),
  ('Pine Tree ''27',     'MEPIN', '2027mepin')
) as v(name, frc_event_code, tba_event_key)
where e.name = v.name
  and e.frc_event_code is null
  and e.tba_event_key is null;


-- =====================================================================
-- 3. Check query — run after the above. Lists every 2026/2027 NE event
--    row now in the table, newest first, so you can eyeball the result.
-- =====================================================================
select name, location, event_date, frc_event_code, tba_event_key
from public.events
where name ~ '''2[67]$'
order by event_date;
