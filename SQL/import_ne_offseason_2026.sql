-- =====================================================================
-- 1307scout: DATA IMPORT ONLY — 2026 New England off-season events
--
-- Row-only changes to public.events. No schema/policy changes. Safe to
-- re-run — every statement checks before writing.
--
-- Source: https://frc-events.firstinspires.org/2026/events/OffSeason,
-- filtered to NH/MA/ME/VT/RI/CT and cross-checked on each event's own
-- page (each explicitly marked "This event is an Off-Season event"),
-- read 2026-11-06. FIRST's off-season list has none in ME, VT, or RI
-- for 2026 — every New England off-season event this year is in NH, MA,
-- or CT. "Week 0" (Feb, Nashua NH) is excluded — it's a pre-season event,
-- not an off-season one.
--
-- event_date is a single day (the column has no event-end date), picked
-- the same way the rest of this project's imports do: the day before
-- the event's last day for a multi-day event, or its one day otherwise.
--
-- Two events already in the table are already-known-about:
--   Governor's Cup '26 (NHHOL) — already present and linked, untouched here.
--   The row currently named "Battle of the Gay/Girls Behind the Glass '26"
--     turns out to be ONE event (Battle Of the Bay, NHALT, Nov 7) with a
--     SECOND, separate event's name accidentally appended to it — "Girls
--     Behind the Glass" (NHALT1, Nov 8) is its own event the next day at
--     the same venue. Section 1 below renames that row back to what it
--     actually is; section 2 adds "Girls Behind the Glass" as its own row.
-- =====================================================================


-- =====================================================================
-- 1. Fix the merged event name (data-quality cleanup, not a new import)
-- =====================================================================
update public.events
set name = 'Battle of the Bay ''26'
where name = 'Battle of the Gay/Girls Behind the Glass ''26';


-- =====================================================================
-- 2. New 2026 NE off-season events
-- =====================================================================
insert into public.events (name, location, event_date, frc_event_code, tba_event_key)
select v.name, v.location, v.event_date::date, v.frc_event_code, v.tba_event_key
from (values
  ('CT State Championship ''26',       'Glastonbury High School, Glastonbury, CT',            '2026-05-17', 'CTGLA',   '2026ctgla'),
  ('BattleCry at WPI 1 ''26',          'WPI - Harrington Auditorium, Worcester, MA',          '2026-05-30', 'MAWOR1',  '2026bc'),
  ('MA State Championship ''26',       'Merrimack College - Lawler Rink, North Andover, MA',  '2026-05-30', 'MANOR',   '2026manor'),
  ('BattleCry at WPI 2 ''26',          'WPI - Harrington Auditorium, Worcester, MA',          '2026-06-06', 'MAWOR2',  '2026bc2'),
  ('Where is Wolcott Invitational ''26','Wolcott High School, Wolcott, CT',                   '2026-06-12', 'CTWOL',   '2026wiwi'),
  ('New England Robotics Derby ''26',  'Billerica Memorial High School, Billerica, MA',       '2026-10-09', 'MABIL1',  '2026matb'),
  ('Mayhem in Merrimack ''26',         'Merrimack High School, Merrimack, NH',                '2026-10-10', 'NHMER',   '2026nhmm'),
  ('CyberKnight Invitational ''26',    'Southington High School, Southington, CT',            '2026-10-17', 'CTSOU',   '2026ctsou'),
  ('RiverRage 29 ''26',                'Manchester Memorial High School, Manchester, NH',     '2026-10-24', 'NHMAN',   '2026nhrr'),
  ('Girls Behind the Glass ''26',      'Prospect Mountain High School, Alton, NH',            '2026-11-08', 'NHALT1',  '2026nhalt1')
) as v(name, location, event_date, frc_event_code, tba_event_key)
where not exists (
  select 1 from public.events e
  where e.name = v.name or e.frc_event_code = v.frc_event_code
);


-- =====================================================================
-- 3. Check query — every 2026 off-season event now in the table.
-- =====================================================================
select name, location, event_date, frc_event_code, tba_event_key
from public.events
where frc_event_code in ('NHHOL','NHALT','NHALT1','CTGLA','MAWOR1','MANOR','MAWOR2',
                          'CTWOL','MABIL1','NHMER','CTSOU','NHMAN')
   or name like '%''26'
order by event_date;
