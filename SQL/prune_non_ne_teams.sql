-- =====================================================================
-- 1307scout: DATA CLEANUP ONLY — prune teams from outside New England
--
-- Row-only changes. No schema, policy or function changes. Safe to
-- re-run: a second run finds nothing left to remove.
--
-- The database has no "state" column for a team, so a team counts as
-- New England if it has competed (or been scouted / scheduled / picked)
-- at a New England event. An event is New England if its location ends
-- in ", NH", ", MA", ", ME", ", VT", ", RI" or ", CT". Events with no
-- location (e.g. "Testing") are treated as home events and kept.
--
-- What this removes:
--   1. Every event located outside New England (the Israel events, and
--      the FIRST Championship unless keep_worlds is true below). Its
--      official matches, scouting/pit entries, playoff picks, tiebreaks,
--      line-ups and schedule edits go with it (on delete cascade).
--      Deleted entries' photos are queued in photo_cleanup_queue as usual.
--   2. team_info rows (names, logos) for every team that isn't a New
--      England team by the rule above. Team 1307 and test teams are kept.
--
-- What it doesn't remove:
--   - Scouting data for a non-NE team at a kept event (only possible at
--     the FIRST Championship when keep_worlds is true).
--   - Logo FILES in the team-logos bucket. SQL can't delete Storage files,
--     so the last query lists the paths to delete in Storage > team-logos.
--   - If keep_worlds is true, the team-names Edge Function will look up a
--     pruned Worlds opponent again (name + avatar) when a page shows it.
--
-- HOW TO RUN: run section 1 on its own first (highlight it > Run) to see
-- what will go. Then run the whole file; it runs as one transaction, so
-- any error leaves the database unchanged.
-- =====================================================================


-- =====================================================================
-- 1. Preview (read-only). Lists every event and team this would remove.
-- =====================================================================
with settings as (select true as keep_worlds),   -- keep in sync with section 2
doomed_events as (
  select e.* from public.events e, settings s
  where e.location is not null
    and e.location !~* ',\s*(NH|MA|ME|VT|RI|CT)\s*$'
    and not (s.keep_worlds and e.event_tier = 'championship')
),
home_events as (
  select e.id from public.events e
  where e.event_tier <> 'championship'
    and e.id not in (select id from doomed_events)
),
home_teams as (
  select unnest(m.red_teams || m.blue_teams) as team_number
    from public.official_matches m where m.event_id in (select id from home_events)
  union select team_number from public.scouting_entries where event_id in (select id from home_events)
  union select team_number from public.pit_entries      where event_id in (select id from home_events)
  union select team_number from public.playoff_picks    where event_id in (select id from home_events)
  union select unnest(red_teams || blue_teams) from public.match_schedule where event_id in (select id from home_events)
  union select team_number from public.test_teams
  union select 1307
)
select 'event' as removes, d.name as what, d.location as detail
  from doomed_events d
union all
select 'team_info', t.team_number::text, coalesce(t.display_name, '')
  from public.team_info t
  where t.team_number not in (select team_number from home_teams where team_number is not null)
order by 1, 2;


-- =====================================================================
-- 2. Prune
-- =====================================================================

-- Set to false to also remove the FIRST Championship (Houston) events,
-- along with every NE team's Worlds results.
create temp table prune_settings on commit drop as
select true as keep_worlds;

-- 2a. Events outside New England
create temp table prune_events on commit drop as
select e.id from public.events e, prune_settings s
where e.location is not null
  and e.location !~* ',\s*(NH|MA|ME|VT|RI|CT)\s*$'
  and not (s.keep_worlds and e.event_tier = 'championship');

delete from public.events where id in (select id from prune_events);

-- 2b. New England teams: anyone seen at a remaining non-championship event
create temp table prune_home_teams on commit drop as
with home_events as (
  select id from public.events where event_tier <> 'championship'
)
select unnest(m.red_teams || m.blue_teams) as team_number
  from public.official_matches m where m.event_id in (select id from home_events)
union select team_number from public.scouting_entries where event_id in (select id from home_events)
union select team_number from public.pit_entries      where event_id in (select id from home_events)
union select team_number from public.playoff_picks    where event_id in (select id from home_events)
union select unnest(red_teams || blue_teams) from public.match_schedule where event_id in (select id from home_events)
union select team_number from public.test_teams
union select 1307;

-- 2c. Remove everyone else's team_info, keeping their logo paths for the list below
create temp table prune_logos on commit drop as
with gone as (
  delete from public.team_info t
  where t.team_number not in (select team_number from prune_home_teams where team_number is not null)
  returning t.team_number, t.logo_url, t.tba_logo_url
)
select g.team_number,
       substring(u from '/storage/v1/object/public/team-logos/([^?]+)') as path
from gone g
cross join lateral unnest(array[g.logo_url, g.tba_logo_url]) as u
where u like '%/storage/v1/object/public/team-logos/%';


-- =====================================================================
-- 3. Result: logo files left in Storage > team-logos for removed teams.
--    Delete these by hand (pasted links from other sites aren't listed).
-- =====================================================================
select (select count(*) from prune_events) as events_removed,
       l.team_number, l.path
from (select 1) one
left join prune_logos l on true   -- still shows the count when no logos are listed
order by l.team_number, l.path;
