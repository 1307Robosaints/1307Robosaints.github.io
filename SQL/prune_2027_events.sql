-- =====================================================================
-- 1307scout: DATA CLEANUP ONLY — remove every 2027 event
--
-- Row-only changes. No schema, policy or function changes. Safe to
-- re-run: a second run finds nothing left to remove.
--
-- An event counts as 2027 if its TBA key starts with 2027, or it has no
-- TBA key and its date is in 2027, or it has neither and its name ends
-- in '27 (this project's naming convention).
--
-- What goes with each event (on delete cascade): its official matches,
-- match and pit scouting entries, playoff picks, tiebreaks, line-ups,
-- schedule edits, vision data and flag reviews. Deleted entries' photos
-- are queued in photo_cleanup_queue as usual, and the Scout page /
-- Staff Portal remove the files.
--
-- Share codes: 2027 events are taken out of each code's event list. A
-- code that covered only 2027 events (and no teams) would then give
-- access to nothing, so it's deleted.
--
-- The 2027 rows came from import_2026_ne_events.sql (section 2 links
-- them), import_championships.sql and import_israel_events.sql, plus
-- rows staff added by hand. Re-running those imports adds 2027 back.
--
-- HOW TO RUN: run section 1 on its own first (highlight it > Run) to see
-- what will go, including how much scouting data each event has. Then
-- run the whole file; it runs as one transaction, so any error leaves
-- the database unchanged.
-- =====================================================================


-- =====================================================================
-- 1. Preview (read-only). Every event this removes, with what's in it.
-- =====================================================================
select e.name, e.event_date, e.frc_event_code, e.tba_event_key,
       (select count(*) from public.scouting_entries s where s.event_id = e.id) as match_entries,
       (select count(*) from public.pit_entries p      where p.event_id = e.id) as pit_entries,
       (select count(*) from public.official_matches m where m.event_id = e.id) as official_matches
from public.events e
where coalesce(substring(e.tba_event_key from '^[0-9]{4}')::int,
               extract(year from e.event_date)::int,
               case when e.name ~ '''27\s*$' then 2027 end) = 2027
order by e.event_date, e.name;


-- =====================================================================
-- 2. Remove
-- =====================================================================
create temp table prune_2027 on commit drop as
select e.id from public.events e
where coalesce(substring(e.tba_event_key from '^[0-9]{4}')::int,
               extract(year from e.event_date)::int,
               case when e.name ~ '''27\s*$' then 2027 end) = 2027;

-- 2a. Take the events out of share codes, then drop codes left with nothing to share
update public.share_codes c
set event_ids = array(select x from unnest(c.event_ids) as x
                      where x not in (select id from prune_2027))
where c.event_ids && array(select id from prune_2027)
  and (cardinality(c.team_numbers) > 0
       or exists (select 1 from unnest(c.event_ids) as x where x not in (select id from prune_2027)));

create temp table prune_2027_codes on commit drop as
with gone as (
  delete from public.share_codes c
  where c.event_ids && array(select id from prune_2027)
  returning c.id
)
select count(*) as n from gone;

-- 2b. The events themselves (everything attached goes with them)
create temp table prune_2027_count on commit drop as
with gone as (
  delete from public.events where id in (select id from prune_2027) returning id
)
select count(*) as n from gone;


-- =====================================================================
-- 3. Result
-- =====================================================================
select (select n from prune_2027_count) as events_removed,
       (select n from prune_2027_codes) as share_codes_removed;
