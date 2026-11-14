-- =====================================================================
-- 1307scout: COMPLETE DATABASE REBUILD (one file, 2026 REBUILT)
--
-- Run once in Supabase: SQL Editor > New query > paste all > Run.
-- Safe to re-run on an existing database (every object is created
-- "if not exists" / "or replace", and policies are dropped first).
--
-- This file replaces every other .sql file in the project:
--   schema.sql, scouting_portal.sql, allowlist.sql, tiers.sql, members.sql,
--   members_v2.sql, migration.sql, 1307scout_setup.sql, official_sync.sql
-- (Verify.sql is replaced by the check query at the very bottom.)
--
-- Sections, in dependency order:
--   0  Base tables (events, scouting_entries)
--   1  Remove objects from earlier versions
--   2  Staff allowlist                       7  Policies for events / match entries
--   3  Grants, students, access levels       8  Official match data (FRC + TBA)
--  3b  Teams: members, managers, join codes, manager requests, team settings
--   4  Form fields (incl. picture fields)     9  Team rating (A-F grade)
--   5  Events, entries, share codes          9b Storage: scouting photos
--   6  Pit entries + validation             10  Guest access via share codes
--  8e  Test teams                           11  Member management (Staff Portal)
--  8f  Team info (names/logos)               8g  Storage: team logos
--  8h  Playoff picks, tiebreaks, line-ups   8i  Match schedule edits
--  8j  Vision data + match flag reviews     8k  Match strategy plans
--  8l  Team member names    8m Scout shifts  8n  Pick list   8o Match predictions
--  8p  Robot log   8q Match alerts   8r Vision pre-fill + relayed entries   8s Public results
--  12  Permissions  13  Form field seed data   14  First staff member
--  15  Optional: schedule the automatic sync    16  Audit log
-- 16b  Teams step 2 (commented out until the Teams release is on stable)
--  17  Check query
--
-- After running, the Edge Function (official-sync) still needs its own
-- secrets and deploy; see the notes in section 15.
--
-- 2026 REBUILT update: section 16 adds an audit log (public.audit_log) that the
-- Staff Portal's "Audit Log" tab searches via staff_search_audit_log(). Most rows
-- are written automatically by a generic trigger on the tables staff/students
-- change (events, scouting/pit entries, form fields, share codes, team info,
-- staff/member grants); a couple of actions that aren't a table write (staff_kick,
-- and manage-member's ban/unban) call public.log_action() directly.
--
-- Member data removal: banning or deleting an account removes its match entries, pit
-- entries and photos through purge_member_data() (section 16), called only by the
-- manage-member and delete-account Edge Functions. Unbanning doesn't restore them.
--
-- 2026 REBUILT update: scout_fields.field_type now also accepts 'image',
-- so staff can add a field ("Robot photo", scope = pit) that lets scouts
-- attach a picture of a team's robot from the Scout page. The photo itself
-- is stored in the "scouting-photos" Storage bucket created in section 9b;
-- the entry's data just holds that photo's public URL as a string.
--
-- Hardening update: log_action() is no longer callable from the API; share-code guesses are
-- throttled per account (share_code_attempts, section 5); photo URLs must point at this
-- project's bucket; entries have a size cap; storage files can't be listed anonymously; pit
-- entries stamp their own editor and time. If this project is ever moved to a new Supabase
-- ref, update the URL pattern in validate_data() (section 6).
--
-- Second hardening update: an "Unsure" answer must really be blank; retired photo fields keep the
-- URL rule; banned accounts can't redeem share codes; guesses from one account run one at a time.
--
-- Photo cleanup update: deleting an entry or replacing its photo now queues the old file for
-- removal, and the Scout page and Staff Portal delete it through the Storage API (section 9b).
--
-- Later update: events now have an event_tier ('offseason', 'qualifier',
-- 'district_championship', or 'championship'), set per event in the Staff
-- Portal. team_official_ratings() (section 9) weights each match by its
-- event's tier via event_tier_weight() — a win or a high score at a
-- District Championship or the FIRST Championship counts for more than
-- the same result at a regular qualifier, and an off-season result
-- counts for a little less.
--
-- Vision update: section 8j adds vision_matches / vision_robots, written only by the vision
-- worker (vision/ folder, service role), and match_flag_reviews for the Match Flags page.
--
-- Alliances update: playoff_picks.source, and official_set_alliances() (section 8h), which the
-- official-alliances Edge Function calls after each sync to copy FRC/TBA alliances into the picks.
--
-- Strategy update: section 8k adds match_strategies, the field-map plan for each match drawn on
-- the Match Strategy page (strategy.html), kept so the team can look back at plans that worked.
--
-- Scouting-tools update: 8l team member names, 8m scout shifts (shifts.html), 8n the pick list
-- (picklist.html), 8o match predictions and their calibration (matches.html, ratings.html),
-- 8p the robot log (pitcrew.html), 8q match alerts (push notifications, match-alerts Edge
-- Function), 8r vision pre-fill and QR-relayed entries (scout.html), 8s public season results
-- (results.html, the only function anon can call).
--
-- Teams update: section 3b gives each FRC team its own members, managers (verified by site staff,
-- then vouching for others), join codes and settings. Strategy plans, the robot log, the pick list
-- and scout shifts belong to a team (owner_team); scouting data stays shared by every team.
--
-- Share codes update: any team member can make one (section 5, the Share Data page), not only
-- staff. A code belongs to its creator and their team, and works only while the creator is on a team.
-- =====================================================================


-- =====================================================================
-- 0. Base tables
--    RECONSTRUCTED from how the other scripts and the site use them (the
--    original base schema was never saved with the project). On an
--    existing database these statements change nothing, so any extra
--    columns you already have are kept.
-- =====================================================================
create table if not exists public.events (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(name) between 1 and 200),
  created_at timestamptz not null default now()
);

create table if not exists public.scouting_entries (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references public.events(id) on delete cascade,
  team_number  int  not null check (team_number between 1 and 99999),
  match_number int  check (match_number between 1 and 999),
  scouted_by   uuid not null default auth.uid() references auth.users(id),
  created_at   timestamptz not null default now()
);
create index if not exists scouting_entries_event_team_idx
  on public.scouting_entries (event_id, team_number);


-- =====================================================================
-- 1. Remove policies and objects from earlier versions
-- =====================================================================
drop policy if exists "members read events"   on public.events;
drop policy if exists "members add events"    on public.events;
drop policy if exists "members edit events"   on public.events;
drop policy if exists "staff read events"     on public.events;
drop policy if exists "members read entries"  on public.scouting_entries;
drop policy if exists "members add entries"   on public.scouting_entries;
drop policy if exists "members delete own"    on public.scouting_entries;
drop policy if exists "staff read entries"    on public.scouting_entries;
drop policy if exists "staff add entries"     on public.scouting_entries;
drop policy if exists "staff delete own"      on public.scouting_entries;

drop function if exists public.staff_set_role(uuid, boolean);
drop function if exists public.is_member();
drop table if exists public.member_access;


-- =====================================================================
-- 2. Staff allowlist. Changed from the SQL Editor or by staff through staff_set_level().
-- =====================================================================
create table if not exists public.staff_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  note text,
  added_at timestamptz not null default now()
);
alter table public.staff_members enable row level security;
revoke all on public.staff_members from anon, authenticated;

-- A Supabase access token stays valid (by signature) until it expires, even after its
-- session row is deleted by staff_kick() -- Supabase's own docs confirm this. Every JWT
-- carries a required session_id claim, so checking it against auth.sessions here is what
-- makes "Sign out" actually take effect immediately instead of waiting out the token's TTL.
create or replace function public.session_live() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from auth.sessions
    where id = (auth.jwt() ->> 'session_id')::uuid
  );
$$;

-- An account's name: the one set on sign-up or My Account (display_name), else the name Google
-- gave (full_name or name). Null if none; callers fall back to the email. js/auth.js copies a
-- Google name into display_name and asks anyone with no name, so this is rarely null.
create or replace function public.account_name(p_meta jsonb) returns text
language sql immutable set search_path = '' as $$
  select coalesce(nullif(btrim(left(p_meta ->> 'display_name', 60)), ''),
                  nullif(btrim(left(p_meta ->> 'full_name', 60)), ''),
                  nullif(btrim(left(p_meta ->> 'name', 60)), ''));
$$;

-- Staff = verified login on the allowlist, not banned, current session not kicked
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.staff_members s
    join auth.users u on u.id = s.user_id
    where s.user_id = auth.uid()
      and u.email_confirmed_at is not null
      and (u.banned_until is null or u.banned_until <= now())
  ) and public.session_live();
$$;


-- =====================================================================
-- 3. Manual grants and student access
-- =====================================================================
-- Grants for mentors, students on personal emails, and explicit guests
create table if not exists public.member_grants (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  level      text not null check (level in ('mentor','student','guest')),
  granted_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);
alter table public.member_grants enable row level security;
revoke all on public.member_grants from anon, authenticated;

-- =====================================================================
-- 3b. Teams: each FRC team has its own members, managers and settings
--
--    Scouting data (match and pit entries, official results, flags, playoff alliances) is
--    shared by every team. What a team does with it is its own: strategy plans, the pit
--    crew's robot log, the pick list and scout shifts carry an owner_team, and only that
--    team's members can see them (sections 8k-8p).
--
--    An account is on at most one team. member_team() decides which: its team_members row
--    (role 'removed' means no team). Quarantine (app_settings.require_team_claims) is on: an
--    unverified account is a guest, with its status shown. One exception keeps the stable release
--    (which has no team prompt) working: a login at teams.email_domain (stalux.org) is a member of
--    that team until the account answers the prompt. If staff turn quarantine off, the rules from
--    before teams existed count again (legacy_team()): staff are home-team managers, mentor/student
--    grants are home-team members, a teams.email_domain login is a member.
--
--    Joining a team: every account says which FRC team it's on, or that it isn't on one
--    (team_claims; the sign-up form asks, and every page prompts an account that hasn't said).
--    A claim is verified at once when the email's domain is on the team's list (team_domains),
--    the team's managers invited that email (team_invites), or staff had already given the
--    account that team (legacy_team()). Any other claim waits ("quarantine": a guest, with its
--    status shown) until one of the team's managers or site staff verifies it (verify_team_claim()).
--    Join codes from a manager also verify. Site staff can act as any team (staff_members.acting_team),
--    which makes them its manager everywhere, so they can see every page and manage every setting.
--
--    Becoming a manager: the person files a request (request_team_manager()), and site staff
--    check it with the team outside the app and approve it in the Staff Portal's Teams tab
--    (staff_review_team_request()). That makes the team verified if it wasn't. After that,
--    managers vouch for others: they make join codes for members and promote members to
--    manager on the Team Management page (team.html), with no staff step.
--
--    A team is a "team member" for the old access checks: is_student() is true for anyone
--    member_team() places on a team, so my_access_level() still answers 'staff', 'student'
--    or 'guest' and the current pages need no change. The team role is separate, from
--    my_team_info(). Site staff get no special access to another team's own data.
-- =====================================================================
-- The team every account from before teams existed belongs to
create or replace function public.home_team() returns int
language sql immutable set search_path = '' as $$ select 1307 $$;

-- A row here means site staff verified the team
create table if not exists public.teams (
  team_number  int primary key check (team_number between 1 and 99999),
  email_domain text unique check (email_domain ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$' and char_length(email_domain) <= 100),
  settings     jsonb not null default '{}'::jsonb
               check (jsonb_typeof(settings) = 'object' and octet_length(settings::text) <= 20000),
  verified_by  uuid references auth.users(id) on delete set null,
  verified_at  timestamptz not null default now()
);
alter table public.teams enable row level security;
insert into public.teams (team_number, email_domain) values (public.home_team(), 'stalux.org')
  on conflict (team_number) do nothing;

create table if not exists public.team_members (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  team_number int  not null references public.teams(team_number) on delete cascade,
  role        text not null check (role in ('manager','member','removed')),
  added_by    uuid references auth.users(id) on delete set null,
  added_at    timestamptz not null default now()
);
create index if not exists team_members_team_idx on public.team_members (team_number);
alter table public.team_members enable row level security;
revoke all on public.team_members from anon, authenticated;

-- Site-wide switches (one row). require_team_claims ("quarantine"): only a verified team_members
-- row puts an account on a team, apart from the home team's domain rule below. Staff can turn it
-- off in the Staff Portal's Teams tab. quarantine_since records when it was first turned on, so a
-- re-run of this file never turns it back on after staff turned it off.
create table if not exists public.app_settings (
  id                  boolean primary key default true check (id),
  require_team_claims boolean not null default true,
  updated_at          timestamptz not null default now()
);
alter table public.app_settings add column if not exists quarantine_since timestamptz;
insert into public.app_settings (id, quarantine_since) values (true, now()) on conflict (id) do nothing;
update public.app_settings set require_team_claims = true, quarantine_since = now(), updated_at = now()
 where id and quarantine_since is null;
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

create or replace function public.require_team_claims() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select a.require_team_claims from public.app_settings a where a.id), false);
$$;

-- Staff: the team they're acting as (null = their own), and whether they skip the team prompt
alter table public.staff_members add column if not exists acting_team int check (acting_team between 1 and 99999);
alter table public.staff_members add column if not exists no_team_prompt boolean not null default false;

-- Login domains that verify a claim to the team at once, set by its managers. Free email
-- providers are refused (is_free_email_domain()). A school with two teams can list it on both,
-- since a domain only verifies people who claimed that team.
create table if not exists public.team_domains (
  team_number int  not null references public.teams(team_number) on delete cascade,
  domain      text not null check (domain ~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$' and char_length(domain) <= 100),
  added_by    uuid default auth.uid() references auth.users(id) on delete set null,
  added_at    timestamptz not null default now(),
  primary key (team_number, domain)
);
alter table public.team_domains enable row level security;
-- The domain staff set before team_domains existed (stalux.org for 1307), for a team with none
insert into public.team_domains (team_number, domain)
select t.team_number, t.email_domain from public.teams t
where t.email_domain is not null and not exists (select 1 from public.team_domains d where d.team_number = t.team_number)
on conflict do nothing;

create or replace function public.is_free_email_domain(p_domain text) returns boolean
language sql immutable set search_path = '' as $$
  select lower(p_domain) = any (array['gmail.com','googlemail.com','yahoo.com','ymail.com','outlook.com','hotmail.com',
    'live.com','msn.com','icloud.com','me.com','mac.com','aol.com','proton.me','protonmail.com','pm.me','gmx.com',
    'gmx.net','mail.com','yandex.com','zoho.com','comcast.net','verizon.net','att.net']);
$$;

-- What each account said about its team. team_number null: not on an FRC team.
--   status 'none' (not on a team), 'pending' (quarantine), 'verified', 'denied'
create table if not exists public.team_claims (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  team_number int  check (team_number between 1 and 99999),
  status      text not null check (status in ('none','pending','verified','denied')),
  how         text check (how in ('domain','invite','code','manager','staff','existing')),
  created_at  timestamptz not null default now(),
  decided_by  uuid references auth.users(id) on delete set null,
  decided_at  timestamptz,
  note        text check (char_length(note) <= 300),
  check ((team_number is null) = (status = 'none'))
);
create index if not exists team_claims_team_idx on public.team_claims (team_number, status);
alter table public.team_claims enable row level security;
drop policy if exists "own team claim" on public.team_claims;
create policy "own team claim" on public.team_claims for select to authenticated
  using (user_id = auth.uid() or (select public.is_staff()));

-- Invitations by email from a team's managers. The invited account sees it when signed in with
-- that email (no email is sent), and accepting, or claiming the team, verifies it.
create table if not exists public.team_invites (
  id          bigint generated always as identity primary key,
  team_number int  not null references public.teams(team_number) on delete cascade,
  email       text not null check (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' and char_length(email) <= 254),
  role        text not null default 'member' check (role in ('member','manager')),
  invited_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '30 days',
  unique (team_number, email)
);
alter table public.team_invites enable row level security;

-- The rules from before teams existed (see the section comment). Internal.
create or replace function public.legacy_team(p_user uuid)
returns table (team_number int, role text)
language sql stable security definer set search_path = '' as $$
  select x.team_number, x.role
  from (
    select public.home_team() as team_number, 'manager'::text as role, 2 as pri
      from public.staff_members s where s.user_id = p_user
    union all
    select public.home_team(), 'member', 3 from public.member_grants g
      where g.user_id = p_user and g.level in ('mentor','student')
    union all
    select t.team_number, 'member', 4
      from auth.users u join public.teams t on t.email_domain = lower(split_part(u.email::text, '@', 2))
      where u.id = p_user
        and not exists (select 1 from public.member_grants g where g.user_id = u.id and g.level = 'guest')
  ) x
  order by x.pri
  limit 1;
$$;
revoke all on function public.legacy_team(uuid) from public, anon, authenticated;

-- An account's team and role. Internal: pages use my_team_info().
create or replace function public.member_team(p_user uuid)
returns table (team_number int, role text)
language sql stable security definer set search_path = '' as $$
  select x.team_number, x.role
  from (
    select m.team_number, m.role, 1 as pri from public.team_members m where m.user_id = p_user
    union all
    select l.team_number, l.role, 2 from public.legacy_team(p_user) l where not public.require_team_claims()
    union all
    -- With quarantine on, a login at a team's staff-set domain (stalux.org for 1307) is still a
    -- member until the account answers the team prompt: the stable release can't ask, and the
    -- domain already verifies them. Once they answer, team_claims and team_members decide.
    select t.team_number, 'member', 3
      from auth.users u join public.teams t on t.email_domain = lower(split_part(u.email::text, '@', 2))
      where u.id = p_user and public.require_team_claims()
        and not exists (select 1 from public.team_claims c where c.user_id = p_user)
        and not exists (select 1 from public.member_grants g where g.user_id = u.id and g.level = 'guest')
  ) x
  where exists (select 1 from auth.users u where u.id = p_user and u.email_confirmed_at is not null
                  and (u.banned_until is null or u.banned_until <= now()))
    and (x.pri = 1 or not exists (select 1 from public.team_members m where m.user_id = p_user))
    and x.role <> 'removed'
  order by x.pri
  limit 1;
$$;
revoke all on function public.member_team(uuid) from public, anon, authenticated;

-- The caller's team for every team page and policy: the team site staff are acting as, else
-- their own. Acting staff are that team's manager. Internal.
create or replace function public.my_team_role()
returns table (team_number int, role text, acting boolean)
language sql stable security definer set search_path = '' as $$
  select x.team_number, x.role, x.acting
  from (
    select s.acting_team as team_number, 'manager'::text as role, true as acting, 1 as pri
      from public.staff_members s join public.teams t on t.team_number = s.acting_team
      where s.user_id = auth.uid() and public.is_staff()
    union all
    select m.team_number, m.role, false, 2 from public.member_team(auth.uid()) m
  ) x
  where public.session_live()
  order by x.pri
  limit 1;
$$;
revoke all on function public.my_team_role() from public, anon, authenticated;

-- Records what an account said about its team. Internal.
create or replace function public.set_team_claim(p_user uuid, p_team int, p_status text, p_how text,
  p_by uuid default null, p_note text default null)
returns void language sql security definer set search_path = '' as $$
  insert into public.team_claims as c (user_id, team_number, status, how, created_at, decided_by, decided_at, note)
  values (p_user, p_team, p_status, p_how, now(), p_by,
          case when p_status in ('verified','denied') then now() end, nullif(left(trim(p_note), 300), ''))
  on conflict (user_id) do update set team_number = excluded.team_number, status = excluded.status,
    how = excluded.how, decided_by = excluded.decided_by, decided_at = excluded.decided_at, note = excluded.note,
    -- The waiting time restarts only when the claim changes team or goes back to waiting
    created_at = case when c.team_number is distinct from excluded.team_number
                        or (c.status <> excluded.status and excluded.status = 'pending')
                      then now() else c.created_at end;
$$;
revoke all on function public.set_team_claim(uuid, int, text, text, uuid, text) from public, anon, authenticated;

-- Puts an account on a team (verified) and records why. Internal.
create or replace function public.add_team_member(p_user uuid, p_team int, p_role text, p_how text, p_by uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  insert into public.team_members (user_id, team_number, role, added_by)
  values (p_user, p_team, p_role, p_by)
  on conflict (user_id) do update set team_number = excluded.team_number, role = excluded.role,
    added_by = excluded.added_by, added_at = now();
  perform public.set_team_claim(p_user, p_team, 'verified', p_how, p_by);
end $$;
revoke all on function public.add_team_member(uuid, int, text, text, uuid) from public, anon, authenticated;

create or replace function public.my_team() returns int
language sql stable security definer set search_path = '' as $$
  select (select r.team_number from public.my_team_role() r);
$$;

create or replace function public.is_team_manager() returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select r.role = 'manager' from public.my_team_role() r), false);
$$;

-- Team features a manager can open to every member or keep to managers. Strategy and the pit
-- crew log start open, and so do share codes; the pick list and scout shifts start with managers,
-- as they were staff-only.
create or replace function public.team_feature_default(p_feature text) returns text
language sql immutable set search_path = '' as $$
  select case when p_feature in ('pick_list', 'scout_shifts') then 'managers' else 'members' end;
$$;

-- Can the caller change this team feature? Managers always can.
create or replace function public.team_can(p_feature text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select r.role = 'manager'
        or coalesce(t.settings -> 'permissions' ->> p_feature, public.team_feature_default(p_feature)) = 'members'
    from public.my_team_role() r join public.teams t on t.team_number = r.team_number
  ), false);
$$;

-- Requests to manage a team, reviewed by site staff
create table if not exists public.team_manager_requests (
  id           bigint generated always as identity primary key,
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  team_number  int  not null check (team_number between 1 and 99999),
  role_on_team text not null check (char_length(role_on_team) between 1 and 80),
  message      text not null check (char_length(message) between 1 and 1000),
  status       text not null default 'pending' check (status in ('pending','approved','denied')),
  created_at   timestamptz not null default now(),
  reviewed_by  uuid references auth.users(id) on delete set null,
  reviewed_at  timestamptz,
  review_note  text check (char_length(review_note) <= 500)
);
create index if not exists team_manager_requests_status_idx on public.team_manager_requests (status, created_at);
create unique index if not exists team_manager_requests_one_pending
  on public.team_manager_requests (user_id) where status = 'pending';
alter table public.team_manager_requests enable row level security;
drop policy if exists "own team requests"           on public.team_manager_requests;
drop policy if exists "withdraw own pending request" on public.team_manager_requests;
create policy "own team requests" on public.team_manager_requests for select to authenticated
  using (user_id = auth.uid() or (select public.is_staff()));
create policy "withdraw own pending request" on public.team_manager_requests for delete to authenticated
  using (user_id = auth.uid() and status = 'pending');

-- Join codes a manager makes for team members. 12 random hex digits, shown as XXXX-XXXX-XXXX.
create or replace function public.gen_join_code() returns text
language sql volatile set search_path = '' as $$
  select upper(regexp_replace(substr(replace(gen_random_uuid()::text, '-', ''), 1, 12), '(....)(....)(....)', '\1-\2-\3'));
$$;
create table if not exists public.team_join_codes (
  code        text primary key default public.gen_join_code(),
  team_number int  not null default public.my_team() references public.teams(team_number) on delete cascade,
  label       text check (char_length(label) <= 80),
  expires_at  timestamptz,
  max_uses    int check (max_uses between 1 and 500),
  use_count   int not null default 0,
  revoked     boolean not null default false,
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.team_join_codes enable row level security;
drop policy if exists "managers read join codes"   on public.team_join_codes;
drop policy if exists "managers add join codes"    on public.team_join_codes;
drop policy if exists "managers revoke join codes" on public.team_join_codes;
drop policy if exists "managers delete join codes" on public.team_join_codes;
create policy "managers read join codes" on public.team_join_codes for select to authenticated
  using (team_number = (select public.my_team()) and (select public.is_team_manager()));
create policy "managers add join codes" on public.team_join_codes for insert to authenticated
  with check (team_number = (select public.my_team()) and (select public.is_team_manager())
              and created_by = auth.uid() and use_count = 0 and not revoked);
create policy "managers revoke join codes" on public.team_join_codes for update to authenticated
  using (team_number = (select public.my_team()) and (select public.is_team_manager()))
  with check (team_number = (select public.my_team()));
create policy "managers delete join codes" on public.team_join_codes for delete to authenticated
  using (team_number = (select public.my_team()) and (select public.is_team_manager()));

-- Everything a page needs about the caller's team, in one call (js/auth.js caches it)
-- plpgsql so it can be created before team_info (section 8f) exists
create or replace function public.my_team_info() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid   uuid := auth.uid();
  v_email text;
  v_team  jsonb;
  v_claim public.team_claims;
begin
  if v_uid is null or not public.session_live() then return null; end if;
  select lower(u.email::text) into v_email from auth.users u where u.id = v_uid;
  select * into v_claim from public.team_claims c where c.user_id = v_uid;
  select jsonb_build_object(
      'team_number', r.team_number,
      'role', r.role,
      'staff_acting', r.acting,
      'name', coalesce(i.display_name, 'Team ' || r.team_number),
      'settings', t.settings,
      'can', (select jsonb_object_agg(f, r.role = 'manager'
                 or coalesce(t.settings -> 'permissions' ->> f, public.team_feature_default(f)) = 'members')
              from unnest(array['strategy','pit_crew','pick_list','scout_shifts','share_codes']) f))
    into v_team
    from public.my_team_role() r
    join public.teams t on t.team_number = r.team_number
    left join public.team_info i on i.team_number = r.team_number;
  return coalesce(v_team, jsonb_build_object('team_number', null)) || jsonb_build_object(
    'is_staff', public.is_staff(),
    'require_claims', public.require_team_claims(),
    -- Ask which team this account is on: it hasn't said, and isn't on a team by a row
    'needs_prompt', v_claim.user_id is null
      and not exists (select 1 from public.team_members m where m.user_id = v_uid and m.role <> 'removed')
      and not exists (select 1 from public.staff_members s where s.user_id = v_uid and s.no_team_prompt),
    'claim', case when v_claim.user_id is null then null else jsonb_build_object(
      'team_number', v_claim.team_number, 'status', v_claim.status, 'created_at', v_claim.created_at,
      'note', v_claim.note) end,
    'invites', coalesce((
      select jsonb_agg(jsonb_build_object('id', iv.id, 'team_number', iv.team_number, 'role', iv.role,
               'name', coalesce(i.display_name, 'Team ' || iv.team_number)) order by iv.created_at)
      from public.team_invites iv left join public.team_info i on i.team_number = iv.team_number
      where iv.email = v_email and iv.expires_at > now()), '[]'::jsonb),
    'request', (
      select jsonb_build_object('id', r.id, 'team_number', r.team_number, 'status', r.status,
                                'created_at', r.created_at, 'review_note', r.review_note)
      from public.team_manager_requests r where r.user_id = v_uid
      order by r.created_at desc limit 1));
end $$;

-- The caller's team, for Team Management. Emails are shown to managers only.
create or replace function public.team_roster()
returns table (user_id uuid, name text, email text, role text, how text, added_at timestamptz, last_sign_in timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_team int := public.my_team();
  v_mgr  boolean := public.is_team_manager();
begin
  if v_team is null then raise exception 'You are not on a team.'; end if;
  return query
    select u.id,
           coalesce(public.account_name(u.raw_user_meta_data), split_part(u.email::text, '@', 1)),
           case when v_mgr then u.email::text end,
           m.role,
           (case when tm.user_id is not null then 'added'
                 when exists (select 1 from public.staff_members s where s.user_id = u.id) then 'staff'
                 when exists (select 1 from public.member_grants g where g.user_id = u.id) then 'grant'
                 else 'domain' end)::text,
           coalesce(tm.added_at, u.created_at),
           u.last_sign_in_at
    from auth.users u
    cross join lateral public.member_team(u.id) m
    left join public.team_members tm on tm.user_id = u.id
    where m.team_number = v_team
    order by m.role, 2;
end $$;

-- A manager makes someone on their team a manager or a member, or takes them off the team.
-- A team always keeps at least one manager.
create or replace function public.team_set_role(target uuid, new_role text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_team int := public.my_team();
  v_old  text;
begin
  if not public.is_team_manager() then raise exception 'Team managers only.'; end if;
  if new_role not in ('manager','member','removed') then raise exception 'Unknown team role.'; end if;
  select m.role into v_old from public.member_team(target) m where m.team_number = v_team;
  if v_old is null then raise exception 'That account is not on your team.'; end if;
  if v_old = 'manager' and new_role <> 'manager'
     and (select count(*) from auth.users u cross join lateral public.member_team(u.id) m
          where m.team_number = v_team and m.role = 'manager') <= 1 then
    raise exception 'Your team needs at least one manager. Make someone else a manager first.';
  end if;
  insert into public.team_members (user_id, team_number, role, added_by)
  values (target, v_team, new_role, auth.uid())
  on conflict (user_id) do update set team_number = excluded.team_number, role = excluded.role,
    added_by = excluded.added_by, added_at = now();
  -- Someone taken off the team is asked again which team they're on; a claim back to this team
  -- then waits for a manager, even from the team's domain (claim_team())
  if new_role = 'removed' then
    delete from public.team_claims where user_id = target;
  else
    perform public.set_team_claim(target, v_team, 'verified', 'manager', auth.uid());
  end if;
end $$;

-- Anyone on a team can leave it, except its last manager
create or replace function public.team_leave() returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_team int;
  v_role text;
begin
  select m.team_number, m.role into v_team, v_role from public.member_team(auth.uid()) m;
  if v_team is null or not public.session_live() then raise exception 'You are not on a team.'; end if;
  if v_role = 'manager'
     and (select count(*) from auth.users u cross join lateral public.member_team(u.id) m
          where m.team_number = v_team and m.role = 'manager') <= 1 then
    raise exception 'You are the last manager. Make someone else a manager before you leave.';
  end if;
  insert into public.team_members (user_id, team_number, role, added_by)
  values (auth.uid(), v_team, 'removed', auth.uid())
  on conflict (user_id) do update set team_number = excluded.team_number, role = 'removed',
    added_by = excluded.added_by, added_at = now();
  delete from public.team_claims where user_id = auth.uid();   -- asked again which team they're on
end $$;

-- Join a team with a code from one of its managers. Wrong codes count toward the same
-- per-account guess limit as share codes (share_code_attempts, section 5).
create or replace function public.join_team(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid  uuid := auth.uid();
  v_code public.team_join_codes;
begin
  if v_uid is null or not public.session_live() or not exists (
    select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null
      and (u.banned_until is null or u.banned_until <= now())) then
    raise exception 'Sign in with a confirmed account first.';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 0));
  delete from public.share_code_attempts where attempted_at < now() - interval '10 minutes';
  if (select count(*) from public.share_code_attempts where user_id = v_uid) >= 10 then
    return jsonb_build_object('error', 'rate_limited');
  end if;

  select * into v_code from public.team_join_codes c
  where c.code = regexp_replace(regexp_replace(upper(coalesce(p_code, '')), '[^0-9A-F]', '', 'g'),
                                '^(....)(....)(....)$', '\1-\2-\3')
    and not c.revoked
    and (c.expires_at is null or c.expires_at > now())
    and (c.max_uses is null or c.use_count < c.max_uses);
  if v_code.code is null then
    insert into public.share_code_attempts (user_id) values (v_uid);
    return jsonb_build_object('error', 'invalid');
  end if;
  if exists (select 1 from public.team_members m where m.user_id = v_uid and m.role in ('manager','member')
             and m.team_number = v_code.team_number) then
    return jsonb_build_object('team_number', v_code.team_number, 'already', true);
  end if;
  if exists (select 1 from public.team_members m where m.user_id = v_uid and m.role in ('manager','member')) then
    return jsonb_build_object('error', 'on_team',
      'team_number', (select m.team_number from public.team_members m where m.user_id = v_uid));
  end if;

  perform public.add_team_member(v_uid, v_code.team_number, 'member', 'code', v_code.created_by);
  update public.team_join_codes set use_count = use_count + 1 where code = v_code.code;
  return jsonb_build_object('team_number', v_code.team_number);
end $$;

-- A manager saves the team's settings: who can change each feature, and the pit crew setup.
-- Shape: { permissions: { strategy|pit_crew|pick_list|scout_shifts|share_codes: 'members'|'managers' },
--          pit: { checklist: [up to 30 items of up to 120 characters], low_volts: 10-14 } }
create or replace function public.team_update_settings(p_settings jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_perm jsonb := coalesce(p_settings -> 'permissions', '{}'::jsonb);
  v_pit  jsonb := coalesce(p_settings -> 'pit', '{}'::jsonb);
  v_list jsonb := v_pit -> 'checklist';
begin
  if not public.is_team_manager() then raise exception 'Team managers only.'; end if;
  if jsonb_typeof(p_settings) <> 'object' or jsonb_typeof(v_perm) <> 'object' or jsonb_typeof(v_pit) <> 'object' then
    raise exception 'Settings must be an object.';
  end if;
  if exists (select 1 from jsonb_each(v_perm) e
             where e.key not in ('strategy','pit_crew','pick_list','scout_shifts','share_codes')
                or e.value not in ('"members"'::jsonb, '"managers"'::jsonb)) then
    raise exception 'Unknown permission setting.';
  end if;
  if v_list is not null and (jsonb_typeof(v_list) <> 'array' or jsonb_array_length(v_list) > 30
       or exists (select 1 from jsonb_array_elements(v_list) i
                  where jsonb_typeof(i) <> 'string' or char_length(i #>> '{}') not between 1 and 120)) then
    raise exception 'The checklist takes up to 30 items of up to 120 characters.';
  end if;
  if v_pit ? 'low_volts' and (jsonb_typeof(v_pit -> 'low_volts') <> 'number'
       or (v_pit ->> 'low_volts')::numeric not between 10 and 14) then
    raise exception 'The low-battery voltage must be between 10 and 14.';
  end if;
  update public.teams
     set settings = jsonb_build_object('permissions', v_perm, 'pit', v_pit)
   where team_number = public.my_team();
end $$;

-- Ask to manage a team. One open request per account, and at most 5 a week.
create or replace function public.request_team_manager(p_team int, p_role text, p_message text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_id bigint;
begin
  if auth.uid() is null or not public.session_live() or not exists (
    select 1 from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null
      and (u.banned_until is null or u.banned_until <= now())) then
    raise exception 'Sign in with a confirmed account first.';
  end if;
  if p_team is null or p_team not between 1 and 99999 then raise exception 'Enter your team number.'; end if;
  if public.my_team() = p_team and public.is_team_manager() then
    raise exception 'You already manage team %.', p_team;
  end if;
  if exists (select 1 from public.team_manager_requests where user_id = auth.uid() and status = 'pending') then
    raise exception 'You already have a request waiting. Withdraw it to send a different one.';
  end if;
  if (select count(*) from public.team_manager_requests
      where user_id = auth.uid() and created_at > now() - interval '7 days') >= 5 then
    raise exception 'Too many requests this week. Contact the site staff instead.';
  end if;
  insert into public.team_manager_requests (user_id, team_number, role_on_team, message)
  values (auth.uid(), p_team, trim(p_role), trim(p_message))
  returning id into v_id;
  return v_id;
end $$;

-- Staff Portal, Teams tab: open and recent requests, with who sent them
create or replace function public.staff_list_team_requests()
returns table (id bigint, user_id uuid, email text, display_name text, team_number int, team_name text,
               role_on_team text, message text, status text, created_at timestamptz,
               reviewed_at timestamptz, review_note text, team_verified boolean, current_team int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  return query
    select r.id, r.user_id, u.email::text, coalesce(public.account_name(u.raw_user_meta_data), '')::text,
           r.team_number, i.display_name, r.role_on_team, r.message, r.status, r.created_at,
           r.reviewed_at, r.review_note,
           exists (select 1 from public.teams t where t.team_number = r.team_number),
           (select m.team_number from public.member_team(r.user_id) m)
    from public.team_manager_requests r
    join auth.users u on u.id = r.user_id
    left join public.team_info i on i.team_number = r.team_number
    where r.status = 'pending' or r.reviewed_at > now() - interval '60 days'
    order by (r.status = 'pending') desc, r.created_at desc;
end $$;

-- Approve (verifying the team if it's new, and making the person its manager) or deny
create or replace function public.staff_review_team_request(p_id bigint, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_req public.team_manager_requests;
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  select * into v_req from public.team_manager_requests where id = p_id for update;
  if v_req.id is null or v_req.status <> 'pending' then raise exception 'That request is no longer open.'; end if;
  if p_approve then
    insert into public.teams (team_number, verified_by) values (v_req.team_number, auth.uid())
      on conflict (team_number) do nothing;
    perform public.add_team_member(v_req.user_id, v_req.team_number, 'manager', 'staff', auth.uid());
  end if;
  update public.team_manager_requests
     set status = case when p_approve then 'approved' else 'denied' end,
         reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(left(trim(p_note), 500), '')
   where id = p_id;
end $$;

-- Staff Portal, Teams tab: every verified team, its managers and how many members it has
drop function if exists public.staff_list_teams();
create or replace function public.staff_list_teams()
returns table (team_number int, team_name text, domains text[], verified_at timestamptz,
               managers jsonb, member_count int, pending_count int)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  return query
    with roster as (
      select m.team_number, m.role, u.id, u.email::text as email
      from auth.users u cross join lateral public.member_team(u.id) m
    )
    select t.team_number, i.display_name,
           coalesce((select array_agg(d.domain order by d.domain) from public.team_domains d
                     where d.team_number = t.team_number), '{}'::text[]),
           t.verified_at,
           coalesce((select jsonb_agg(jsonb_build_object('user_id', r.id, 'email', r.email) order by r.email)
                     from roster r where r.team_number = t.team_number and r.role = 'manager'), '[]'::jsonb),
           (select count(*)::int from roster r where r.team_number = t.team_number),
           (select count(*)::int from public.team_claims c where c.team_number = t.team_number and c.status = 'pending')
    from public.teams t
    left join public.team_info i on i.team_number = t.team_number
    order by t.team_number;
end $$;

-- Staff put anyone on a team as a manager or member (verifying them, so they leave quarantine),
-- or take them off one (e.g. a manager a team disputes). Putting someone on a team that isn't
-- on 1307scout yet adds the team, the same as approving a request to manage it.
create or replace function public.staff_set_team_role(target uuid, p_team int, new_role text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  if new_role not in ('manager','member','removed') then raise exception 'Unknown team role.'; end if;
  if p_team is null or p_team not between 1 and 99999 then raise exception 'Enter a team number.'; end if;
  if not exists (select 1 from auth.users u where u.id = target) then raise exception 'No such account.'; end if;
  if not exists (select 1 from public.teams where team_number = p_team) then
    if new_role = 'removed' then raise exception 'Team % is not on 1307scout.', p_team; end if;
    insert into public.teams (team_number, verified_by) values (p_team, auth.uid());
  end if;
  if new_role = 'removed' then
    insert into public.team_members (user_id, team_number, role, added_by)
    values (target, p_team, 'removed', auth.uid())
    on conflict (user_id) do update set team_number = excluded.team_number, role = 'removed',
      added_by = excluded.added_by, added_at = now();
    delete from public.team_claims where user_id = target;
  else
    perform public.add_team_member(target, p_team, new_role, 'staff', auth.uid());
  end if;
end $$;

-- Staff set the login domain that puts accounts on a team automatically (blank turns it off).
-- Only for a domain the team alone uses, such as a school's: everyone with it joins as a member.
create or replace function public.staff_set_team_domain(p_team int, p_domain text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  update public.teams set email_domain = nullif(lower(trim(p_domain)), '') where team_number = p_team;
  if not found then raise exception 'That team is not verified.'; end if;
end $$;

-- ── Claims: which team an account is on (see the section comment) ──
-- Called by the team prompt on every page and the sign-up answer. p_team null: not on a team.
-- Returns { status: 'none' | 'pending' | 'verified', team_number, role, team_known }.
create or replace function public.claim_team(p_team int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_email  text;
  v_cur    int;
  v_inv    public.team_invites;
  v_role   text;
  v_how    text;
begin
  if v_uid is null or not public.session_live() or not exists (
    select 1 from auth.users u where u.id = v_uid and u.email_confirmed_at is not null
      and (u.banned_until is null or u.banned_until <= now())) then
    raise exception 'Sign in with a confirmed account first.';
  end if;
  select lower(u.email::text) into v_email from auth.users u where u.id = v_uid;
  select m.team_number into v_cur from public.team_members m where m.user_id = v_uid and m.role in ('manager','member');
  if v_cur is not null then
    if v_cur = p_team then
      perform public.set_team_claim(v_uid, v_cur, 'verified', coalesce((select c.how from public.team_claims c where c.user_id = v_uid), 'existing'));
      return jsonb_build_object('status', 'verified', 'team_number', v_cur);
    end if;
    raise exception 'You are on team %. Leave it on Team Management first.', v_cur;
  end if;
  if p_team is null then
    perform public.set_team_claim(v_uid, null, 'none', null);
    return jsonb_build_object('status', 'none');
  end if;
  if p_team not between 1 and 99999 then raise exception 'Enter your team number.'; end if;

  -- Verified at once by an invitation, the team's domain, or access staff already gave
  if exists (select 1 from public.teams t where t.team_number = p_team) then
    select * into v_inv from public.team_invites iv
     where iv.team_number = p_team and iv.email = v_email and iv.expires_at > now();
    if v_inv.id is not null then
      v_role := v_inv.role; v_how := 'invite';
    elsif exists (select 1 from public.team_domains d
                  where d.team_number = p_team and d.domain = split_part(v_email, '@', 2)) then
      v_role := 'member'; v_how := 'domain';
    else
      select l.role into v_role from public.legacy_team(v_uid) l where l.team_number = p_team;
      if v_role is not null then v_how := 'existing'; end if;
    end if;
    -- Someone a manager took off this team waits for a manager, unless they were invited back
    if v_how in ('domain', 'existing') and exists (
         select 1 from public.team_members m where m.user_id = v_uid and m.team_number = p_team
           and m.role = 'removed' and m.added_by is distinct from v_uid) then
      v_role := null;
    end if;
  end if;

  if v_role is not null then
    perform public.add_team_member(v_uid, p_team, v_role, v_how, v_inv.invited_by);
    if v_inv.id is not null then delete from public.team_invites where id = v_inv.id; end if;
    return jsonb_build_object('status', 'verified', 'team_number', p_team, 'role', v_role);
  end if;
  perform public.set_team_claim(v_uid, p_team, 'pending', null);
  return jsonb_build_object('status', 'pending', 'team_number', p_team,
    'team_known', exists (select 1 from public.teams t where t.team_number = p_team));
end $$;

-- People waiting for the caller's team to verify them (managers, and staff acting as the team)
create or replace function public.team_pending_claims()
returns table (user_id uuid, name text, email text, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_team int := public.my_team();
begin
  if v_team is null or not public.is_team_manager() then raise exception 'Team managers only.'; end if;
  return query
    select u.id,
           coalesce(public.account_name(u.raw_user_meta_data), split_part(u.email::text, '@', 1)),
           u.email::text, c.created_at
    from public.team_claims c join auth.users u on u.id = c.user_id
    where c.team_number = v_team and c.status = 'pending'
    order by c.created_at;
end $$;

-- Verify or deny a waiting claim: a manager of that team, or site staff. Staff can also verify a
-- claim to a team that isn't on 1307scout yet, which verifies the team (best as its manager).
create or replace function public.verify_team_claim(target uuid, p_approve boolean,
  p_role text default 'member', p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_claim public.team_claims;
  v_staff boolean := public.is_staff();
begin
  select * into v_claim from public.team_claims c where c.user_id = target for update;
  if v_claim.user_id is null or v_claim.status <> 'pending' then raise exception 'That person is no longer waiting.'; end if;
  if not v_staff and not (public.is_team_manager() and public.my_team() = v_claim.team_number) then
    raise exception 'Only that team''s managers or site staff can verify it.';
  end if;
  if p_role not in ('member','manager') then raise exception 'Unknown team role.'; end if;
  if not p_approve then
    perform public.set_team_claim(target, v_claim.team_number, 'denied', null, auth.uid(), p_note);
    return;
  end if;
  if not exists (select 1 from public.teams t where t.team_number = v_claim.team_number) then
    if not v_staff then raise exception 'That team is not on 1307scout yet. Site staff verify a new team.'; end if;
    insert into public.teams (team_number, verified_by) values (v_claim.team_number, auth.uid());
  end if;
  perform public.add_team_member(target, v_claim.team_number, p_role,
    case when public.is_team_manager() and public.my_team() = v_claim.team_number
              and not coalesce((select r.acting from public.my_team_role() r), false) then 'manager' else 'staff' end,
    auth.uid());
  update public.team_claims set note = nullif(left(trim(p_note), 300), '') where user_id = target;
end $$;

-- Staff Portal, Teams tab: everyone waiting, on every team
create or replace function public.staff_list_claims()
returns table (user_id uuid, email text, display_name text, team_number int, team_name text,
               team_verified boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  return query
    select c.user_id, u.email::text, coalesce(public.account_name(u.raw_user_meta_data), '')::text,
           c.team_number, i.display_name,
           exists (select 1 from public.teams t where t.team_number = c.team_number), c.created_at
    from public.team_claims c
    join auth.users u on u.id = c.user_id
    left join public.team_info i on i.team_number = c.team_number
    where c.status = 'pending'
    order by c.created_at;
end $$;

-- ── Domains a team's managers set; a claim from one is verified at once ──
create or replace function public.team_add_domain(p_domain text) returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_team int := public.my_team();
  v_d    text := lower(trim(both ' @' from coalesce(p_domain, '')));
  v_n    int := 0;
  r      record;
begin
  if v_team is null or not public.is_team_manager() then raise exception 'Team managers only.'; end if;
  if v_d !~ '^[a-z0-9-]+(\.[a-z0-9-]+)+$' or char_length(v_d) > 100 then
    raise exception 'Enter a domain like yourschool.org.';
  end if;
  if public.is_free_email_domain(v_d) then
    raise exception '% is a free email provider, so it can''t verify anyone. Use your school''s or team''s own domain.', v_d;
  end if;
  if (select count(*) from public.team_domains d where d.team_number = v_team) >= 10 then
    raise exception 'A team can list up to 10 domains.';
  end if;
  insert into public.team_domains (team_number, domain, added_by) values (v_team, v_d, auth.uid())
    on conflict do nothing;
  -- Verify anyone already waiting from this domain (not people a manager took off the team)
  for r in
    select c.user_id from public.team_claims c join auth.users u on u.id = c.user_id
    where c.team_number = v_team and c.status = 'pending' and u.email_confirmed_at is not null
      and lower(split_part(u.email::text, '@', 2)) = v_d
      and not exists (select 1 from public.team_members m where m.user_id = c.user_id and m.team_number = v_team
                        and m.role = 'removed' and m.added_by is distinct from c.user_id)
  loop
    perform public.add_team_member(r.user_id, v_team, 'member', 'domain', auth.uid());
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.team_remove_domain(p_domain text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.my_team() is null or not public.is_team_manager() then raise exception 'Team managers only.'; end if;
  delete from public.team_domains where team_number = public.my_team() and domain = lower(trim(p_domain));
end $$;

-- ── Invitations by email ──
-- Returns 'invited', or 'verified' if that account was already waiting to join this team.
create or replace function public.team_invite(p_email text, p_role text default 'member') returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_team  int := public.my_team();
  v_email text := lower(trim(coalesce(p_email, '')));
  v_user  uuid;
begin
  if v_team is null or not public.is_team_manager() then raise exception 'Team managers only.'; end if;
  if p_role not in ('member','manager') then raise exception 'Unknown team role.'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' or char_length(v_email) > 254 then
    raise exception 'Enter an email address.';
  end if;
  if (select count(*) from public.team_invites iv where iv.team_number = v_team and iv.expires_at > now()) >= 200 then
    raise exception 'Your team has 200 open invitations. Remove some first.';
  end if;
  select u.id into v_user from auth.users u where lower(u.email::text) = v_email and u.email_confirmed_at is not null;
  if v_user is not null and exists (select 1 from public.member_team(v_user) m where m.team_number = v_team) then
    raise exception 'That account is already on your team.';
  end if;
  -- Already waiting to join this team: the invitation verifies them now
  if v_user is not null and exists (select 1 from public.team_claims c
                                    where c.user_id = v_user and c.team_number = v_team and c.status = 'pending') then
    perform public.add_team_member(v_user, v_team, p_role, 'invite', auth.uid());
    return 'verified';
  end if;
  insert into public.team_invites (team_number, email, role, invited_by)
  values (v_team, v_email, p_role, auth.uid())
  on conflict (team_number, email) do update set role = excluded.role, invited_by = excluded.invited_by,
    created_at = now(), expires_at = now() + interval '30 days';
  return 'invited';
end $$;

-- The invited person accepts or declines (only invitations to their own email)
create or replace function public.accept_team_invite(p_id bigint) returns int
language plpgsql security definer set search_path = '' as $$
declare
  v_inv public.team_invites;
begin
  if not public.session_live() then raise exception 'Sign in first.'; end if;
  select iv.* into v_inv from public.team_invites iv join auth.users u on lower(u.email::text) = iv.email
   where iv.id = p_id and u.id = auth.uid() and u.email_confirmed_at is not null and iv.expires_at > now();
  if v_inv.id is null then raise exception 'That invitation is gone or expired.'; end if;
  if exists (select 1 from public.team_members m where m.user_id = auth.uid() and m.role in ('manager','member')
             and m.team_number <> v_inv.team_number) then
    raise exception 'You are on another team. Leave it on Team Management first.';
  end if;
  perform public.add_team_member(auth.uid(), v_inv.team_number, v_inv.role, 'invite', v_inv.invited_by);
  delete from public.team_invites where id = p_id;
  return v_inv.team_number;
end $$;

create or replace function public.decline_team_invite(p_id bigint) returns void
language sql security definer set search_path = '' as $$
  delete from public.team_invites iv using auth.users u
  where iv.id = p_id and u.id = auth.uid() and lower(u.email::text) = iv.email;
$$;

-- ── Site staff ──
-- Act as a team (null: stop), to see its pages and manage it as its manager
create or replace function public.staff_act_as_team(p_team int) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  if p_team is not null and not exists (select 1 from public.teams t where t.team_number = p_team) then
    raise exception 'Team % is not on 1307scout.', p_team;
  end if;
  update public.staff_members set acting_team = p_team where user_id = auth.uid();
end $$;

-- Turn quarantine on: from then on only verified team_members rows put accounts on teams
create or replace function public.staff_set_require_claims(p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  update public.app_settings set require_team_claims = p_on, updated_at = now() where id;
end $$;

drop policy if exists "team reads its domains"     on public.team_domains;
drop policy if exists "managers read invitations"   on public.team_invites;
drop policy if exists "managers delete invitations" on public.team_invites;
create policy "team reads its domains" on public.team_domains for select to authenticated
  using (team_number = (select public.my_team()) or (select public.is_staff()));
create policy "managers read invitations" on public.team_invites for select to authenticated
  using (team_number = (select public.my_team()) and (select public.is_team_manager()));
create policy "managers delete invitations" on public.team_invites for delete to authenticated
  using (team_number = (select public.my_team()) and (select public.is_team_manager()));

drop policy if exists "team reads own team" on public.teams;
create policy "team reads own team" on public.teams for select to authenticated
  using (team_number = (select public.my_team()) or (select public.is_staff()));


-- Student ("team member") = verified, not banned, current session not kicked, and on a team
-- (member_team(), section 3b: a team_members row, a mentor/student grant, or a team's login
-- domain such as @stalux.org). A 'guest' grant turns off the domain rule for that account.
create or replace function public.is_student() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.member_team(auth.uid())) and public.session_live();
$$;

-- One call the site uses to pick a view: 'staff', 'student', or 'guest'
create or replace function public.my_access_level() returns text
language sql stable security definer set search_path = '' as $$
  select case
    when public.is_staff()   then 'staff'
    when public.is_student() then 'student'
    else 'guest'
  end;
$$;


-- =====================================================================
-- 4. Form fields. Staff define them; each field has a scope of
--    'match' or 'pit' that decides which form it appears on.
--
--    field_type 'image' lets a field hold a photo: the Scout page shows a
--    file/camera picker for it, uploads the picture to the "scouting-photos"
--    Storage bucket (section 9b), and saves the resulting public URL as the
--    field's value (a string, same as 'text').
-- =====================================================================
create table if not exists public.scout_fields (
  id uuid primary key default gen_random_uuid(),
  key text not null unique check (key ~ '^[a-z][a-z0-9_]{0,39}$'),
  label text not null check (char_length(label) between 1 and 60),
  field_type text not null check (field_type in ('number','text','choice','boolean','image')),
  options text[],
  min_value numeric,
  max_value numeric,
  required boolean not null default false,
  section text not null default 'Match' check (char_length(section) <= 40),
  sort_order int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (field_type <> 'choice' or (options is not null and cardinality(options) > 0))
);
alter table public.scout_fields add column if not exists scope text not null default 'match'
  check (scope in ('pit','match'));
alter table public.scout_fields add column if not exists is_points boolean not null default false;
alter table public.scout_fields enable row level security;

-- On a database built before 'image'/'slider' existed, widen the existing check constraint
-- in place (the table above was only created, not altered, if it already existed).
alter table public.scout_fields drop constraint if exists scout_fields_field_type_check;
alter table public.scout_fields add constraint scout_fields_field_type_check
  check (field_type in ('number','text','choice','boolean','image','slider'));

-- reg_limit: the FRC-legal max for a physical spec (frame height, weight, ...), shown by the
-- Scout page and Team Database as a flag when a scouted value exceeds it. It is informational
-- only — min_value/max_value (above) are what validate_data() actually enforces, and specs are
-- deliberately left unenforced there (a robot that's slightly over isn't an invalid scouting
-- entry, it's a fact worth flagging) while still getting caught everywhere the value is shown.
alter table public.scout_fields add column if not exists reg_limit numeric;

-- allow_unsure: for a number/slider field where a scout genuinely may not know the figure
-- (e.g. max shooting range), this adds an "Unsure" checkbox next to the input on the Scout page.
-- Checking it clears/disables the number box and saves "<key>__unsure": true instead of a
-- number — see validate_data() below for how that companion key is accepted.
alter table public.scout_fields add column if not exists allow_unsure boolean not null default false;

drop policy if exists "team reads fields"   on public.scout_fields;
drop policy if exists "staff writes fields" on public.scout_fields;
create policy "team reads fields" on public.scout_fields for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "staff writes fields" on public.scout_fields for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));


-- =====================================================================
-- 5. Events, entries, and share codes
-- =====================================================================
alter table public.events add column if not exists location text check (char_length(location) <= 80);
alter table public.events add column if not exists event_date date;

-- Official-data sync settings, set per event in the Staff Portal.
--   frc_event_code   e.g. NHHOL      (FRC Events API; leave blank if FIRST doesn't sync the event)
--   tba_event_key    e.g. 2026nhgc   (The Blue Alliance; year first)
-- The rest is bookkeeping written by the official-sync Edge Function.
alter table public.events add column if not exists frc_event_code       text check (frc_event_code ~ '^[A-Za-z0-9]{2,12}$');
alter table public.events add column if not exists tba_event_key        text check (tba_event_key ~ '^[0-9]{4}[a-z0-9]+$');
alter table public.events add column if not exists official_synced_at   timestamptz;
alter table public.events add column if not exists tba_etag             text;
alter table public.events add column if not exists frc_last_modified    jsonb not null default '{}'::jsonb;
alter table public.events add column if not exists official_sync_status jsonb;
alter table public.events add column if not exists official_sync_note   text;

-- How much this event's official results count toward a team's official rating (section 9).
-- Set per event in the Staff Portal. 'qualifier' (a normal district/regular-season event) is
-- the default for every existing event, so nothing changes until staff mark a championship.
alter table public.events add column if not exists event_tier text not null default 'qualifier'
  check (event_tier in ('offseason','qualifier','district_championship','championship'));

-- The event the Scout page auto-selects, set by staff in the Staff Portal (the "star" button
-- on an event row) instead of scouts having to find the current event in a dropdown of every
-- event the team has ever attended. At most one event can be the default — enforced by the
-- partial unique index below rather than app logic, so a stale UI state can't leave two events
-- both marked default. Setting a new default must first clear the old one in the same request
-- (see set_default_event() below) or the insert/update violates that index.
alter table public.events add column if not exists is_default_event boolean not null default false;
create unique index if not exists events_one_default_idx
  on public.events ((is_default_event)) where is_default_event;

-- Atomically moves the default-event flag to p_event_id (clearing it from wherever it was),
-- so the Staff Portal's star button never has to do the clear-then-set as two separate requests
-- racing the unique index above. Pass null to clear the default entirely.
create or replace function public.set_default_event(p_event_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then
    raise exception 'Only staff can set the default event.';
  end if;
  update public.events set is_default_event = false where is_default_event;
  if p_event_id is not null then
    update public.events set is_default_event = true where id = p_event_id;
  end if;
end $$;
revoke all on function public.set_default_event(uuid) from public, anon;
grant execute on function public.set_default_event(uuid) to authenticated;

-- Competition-day auto-sync: the one event refreshed from FRC/TBA every 2 minutes, chosen by
-- staff with the clock button on an event row. Same one-at-a-time index as the default event.
-- The schedule itself is a pg_cron job calling run_auto_sync() (see section 15).
alter table public.events add column if not exists auto_sync boolean not null default false;
-- When staff turned auto-sync on. run_auto_sync() turns it off 12 hours later, so a flag left on
-- overnight can't keep syncing (each sync costs disk IO the small database needs for logins).
alter table public.events add column if not exists auto_sync_since timestamptz;
update public.events set auto_sync_since = now() where auto_sync and auto_sync_since is null;
-- The pg_net request the last auto-sync run sent, so auto_sync_health() can read its response.
alter table public.events add column if not exists auto_sync_request bigint;
-- The same for the last "Resync data" press (resync_default_event() below).
alter table public.events add column if not exists resync_request bigint;
alter table public.events add column if not exists resync_requested_at timestamptz;
create unique index if not exists events_one_auto_sync_idx
  on public.events ((auto_sync)) where auto_sync;

-- Moves the auto-sync flag to p_event_id in one request. Pass null to turn auto-sync off.
create or replace function public.set_auto_sync_event(p_event_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then
    raise exception 'Only staff can set the auto-sync event.';
  end if;
  if p_event_id is not null and not exists (
    select 1 from public.events
    where id = p_event_id and (frc_event_code is not null or tba_event_key is not null)
  ) then
    raise exception 'Link this event to an FRC or TBA code before turning on auto-sync.';
  end if;
  -- run_auto_sync() would clear the flag on its next run without ever syncing
  if exists (
    select 1 from public.events
    where id = p_event_id and event_date < (now() at time zone 'America/New_York')::date - 4
  ) then
    raise exception 'This event ended more than 4 days ago, so auto-sync won''t run for it. Use the sync button instead.';
  end if;
  update public.events set auto_sync = false, auto_sync_since = null where auto_sync;
  if p_event_id is not null then
    update public.events set auto_sync = true, auto_sync_since = now() where id = p_event_id;
  end if;
end $$;
revoke all on function public.set_auto_sync_event(uuid) from public, anon;
grant execute on function public.set_auto_sync_event(uuid) to authenticated;

-- Sends one official-sync request for an event through pg_net and returns the request id. Shared
-- by auto-sync and the Resync data button; not callable from the API. Sends force=true because the
-- Edge Function otherwise skips events synced under 90 seconds ago. The longer timeout is because
-- pg_net's 5 second default is shorter than a full sync can take. It also asks the
-- official-alliances function for the event's playoff alliances; until that function is deployed,
-- that second request just fails quietly.
create or replace function public.official_sync_request(p_event uuid) returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  v_secret text;
begin
  -- Trimmed, because a space or line break pasted in with the secret makes official-sync refuse it
  select btrim(decrypted_secret, E' \t\r\n') into v_secret from vault.decrypted_secrets where name = 'sync_secret';
  if v_secret is null or v_secret = '' then
    raise exception 'Vault secret sync_secret is missing (see section 15).';
  end if;
  perform net.http_post(
    url     := 'https://nyanwljgsazwuzmnlrcz.supabase.co/functions/v1/official-alliances',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', v_secret),
    body    := jsonb_build_object('event_id', p_event),
    timeout_milliseconds := 30000);
  return net.http_post(
    url     := 'https://nyanwljgsazwuzmnlrcz.supabase.co/functions/v1/official-sync',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', v_secret),
    body    := jsonb_build_object('event_id', p_event, 'force', true),
    timeout_milliseconds := 60000);
end $$;
revoke all on function public.official_sync_request(uuid) from public, anon, authenticated;

-- Called by pg_cron only, every 2 minutes. Turns itself off 12 hours after staff turned it on
-- (one competition day; staff turn it back on each morning), or 4 days after the event, so a
-- forgotten flag can't keep syncing.
create or replace function public.run_auto_sync() returns void
language plpgsql set search_path = '' as $$
declare
  v_event uuid;
begin
  -- Turned on from the SQL Editor instead of the portal: start its 12 hours now
  update public.events set auto_sync_since = now() where auto_sync and auto_sync_since is null;
  update public.events set auto_sync = false, auto_sync_since = null
    where auto_sync and (event_date < (now() at time zone 'America/New_York')::date - 4
                         or auto_sync_since < now() - interval '12 hours');

  select id into v_event from public.events
    where auto_sync and (frc_event_code is not null or tba_event_key is not null);
  if v_event is null then return; end if;

  update public.events set auto_sync_request = public.official_sync_request(v_event) where id = v_event;
end $$;
revoke all on function public.run_auto_sync() from public, anon, authenticated;

-- The "Resync data" button on the team's pages (js/resync.js): refreshes the default event from
-- FRC/TBA right now. Students can't call official-sync themselves (it takes a staff login or the
-- sync secret), so this sends the same request auto-sync does. A press within 60 seconds of the
-- last one gets that request back instead of a new one, so a room full of buttons can't flood
-- the FRC/TBA APIs.
-- The row lock is "for no key update", not "for update": every match row a sync writes takes a key
-- share lock on its event, and "for update" would wait behind those until the API's statement
-- timeout. The lock_timeout makes any other wait fail quickly with a clear message instead.
create or replace function public.resync_default_event() returns jsonb
language plpgsql security definer set search_path = '' set lock_timeout = '3s' as $$
declare
  v_ev      record;
  v_request bigint;
begin
  if not (public.is_staff() or public.is_student()) then
    raise exception 'Only team members can resync data.';
  end if;
  select id, name, frc_event_code, tba_event_key, resync_request, resync_requested_at into v_ev
    from public.events where is_default_event for no key update;
  if not found then
    raise exception 'No default event is set. Staff can pick one with the star in the Staff Portal.';
  end if;
  if v_ev.frc_event_code is null and v_ev.tba_event_key is null then
    raise exception '% isn''t linked to an FRC or TBA code, so there''s nothing to sync. Staff can link it in the Staff Portal.', v_ev.name;
  end if;
  if v_ev.resync_request is not null and v_ev.resync_requested_at > now() - interval '60 seconds' then
    return jsonb_build_object('request_id', v_ev.resync_request, 'event_id', v_ev.id,
                              'event_name', v_ev.name, 'reused', true);
  end if;
  v_request := public.official_sync_request(v_ev.id);
  update public.events set resync_request = v_request, resync_requested_at = now() where id = v_ev.id;
  return jsonb_build_object('request_id', v_request, 'event_id', v_ev.id, 'event_name', v_ev.name, 'reused', false);
exception when lock_not_available then
  raise exception 'The default event is busy being updated. Try Resync again in a few seconds.';
end $$;
revoke all on function public.resync_default_event() from public, anon;
grant execute on function public.resync_default_event() to authenticated;

-- Whether a Resync data request has finished, and how official-sync answered. Only the button's
-- own requests: a request id that isn't any event's resync_request reads as finished.
create or replace function public.resync_status(p_request bigint) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_row record;
begin
  if not (public.is_staff() or public.is_student()) then
    raise exception 'Team members only.';
  end if;
  if not exists (select 1 from public.events where resync_request = p_request) then
    return jsonb_build_object('done', true, 'unknown', true);
  end if;
  select status_code, error_msg, left(content, 300) as body into v_row
    from net._http_response where id = p_request;
  if not found then return jsonb_build_object('done', false); end if;
  return jsonb_build_object('done', true, 'status', v_row.status_code,
                            'error', left(v_row.error_msg, 300), 'body', v_row.body);
end $$;
revoke all on function public.resync_status(bigint) from public, anon;
grant execute on function public.resync_status(bigint) to authenticated;

-- Every part of auto-sync that can fail without anyone seeing it: the cron job, the vault secret,
-- the job's last run, and the Edge Function's last reply. The Staff Portal shows this next to the
-- auto-sync status. A null means this function couldn't look. Staff only, plus the SQL Editor
-- and the check query in section 17, which run with no signed-in user.
create or replace function public.auto_sync_health() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  r       jsonb := '{}'::jsonb;
  v_job   bigint;
  v_sched text;
  v_req   bigint;
  v_row   record;
begin
  if auth.uid() is not null and not public.is_staff() then raise exception 'Staff only.'; end if;

  begin
    select jobid, schedule into v_job, v_sched from cron.job where jobname = 'auto-sync-event' and active;
    r := r || jsonb_build_object('cron_job', v_job is not null, 'schedule', v_sched);
    if v_job is not null then
      select status, return_message, start_time into v_row from cron.job_run_details
       where jobid = v_job order by start_time desc limit 1;
      r := r || jsonb_build_object('last_run_at', v_row.start_time, 'last_run_status', v_row.status,
                                   'last_run_message', left(v_row.return_message, 300));
    end if;
  exception
    when undefined_table or invalid_schema_name then r := r || jsonb_build_object('cron_job', false);
    when others then r := r || jsonb_build_object('cron_job', null);
  end;

  begin
    r := r || jsonb_build_object('vault_secret',
      exists (select 1 from vault.decrypted_secrets where name = 'sync_secret'));
  exception
    when undefined_table or invalid_schema_name then r := r || jsonb_build_object('vault_secret', false);
    when others then r := r || jsonb_build_object('vault_secret', null);
  end;

  -- pg_net only keeps responses for a few hours, so no row here isn't a failure
  select auto_sync_request into v_req from public.events where auto_sync;
  if v_req is not null then
    begin
      select status_code, error_msg into v_row from net._http_response where id = v_req;
      r := r || jsonb_build_object('http_status', v_row.status_code, 'http_error', left(v_row.error_msg, 300));
    exception when others then null;
    end;
  end if;
  return r;
end $$;
revoke all on function public.auto_sync_health() from public, anon;
grant execute on function public.auto_sync_health() to authenticated;

-- Backfill the tier of events already in the table from earlier imports (safe to re-run;
-- only touches rows that already exist, and only sets non-default tiers).
update public.events set event_tier = 'offseason'
  where frc_event_code in ('NHHOL','NHALT','NHALT1','CTGLA','MAWOR1','MANOR','MAWOR2',
                            'CTWOL','MABIL1','NHMER','CTSOU','NHMAN');
update public.events set event_tier = 'district_championship'
  where frc_event_code in ('NECMP','NECMP1','NECMP2');
update public.events set event_tier = 'championship'
  where frc_event_code in ('CMPTX','ARCHIMEDES','CURIE','DALY','GALILEO','HOPPER','JOHNSON','MILSTEIN','NEWTON');

alter table public.scouting_entries add column if not exists data jsonb not null default '{}'::jsonb;

-- An 8-digit numeric code is short enough to read aloud or type from a printed handout, unlike
-- the old 24-character hex code. Collisions are vanishingly unlikely at this team's scale, but
-- the loop guards against one anyway instead of letting the unique constraint fail the insert.
-- The digits come from gen_random_uuid() (its first 48 bits are cryptographically random), not
-- random(), which is predictable. Short codes are only safe alongside the guess limit in
-- get_shared_scouting() (section 10).
create or replace function public.gen_share_code() returns text
language plpgsql set search_path = '' as $$
declare
  c text;
begin
  loop
    c := lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12))::bit(48)::bigint) % 100000000)::text, 8, '0');
    exit when not exists (select 1 from public.share_codes where code = c);
  end loop;
  return c;
end;
$$;

-- Share codes: each can scope to several events and/or several teams at once (arrays, so a
-- code for a whole alliance or a multi-event invite doesn't need to be recreated per
-- event/team), revocable, optional expiry. created_by ties the code to the staff account that
-- made it; use_count/last_used_at track how many times it's actually been redeemed (bumped by
-- get_shared_scouting() in section 10, which is how a QR scan or pasted code shows up here).
create table if not exists public.share_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique default public.gen_share_code(),
  label text not null check (char_length(label) between 1 and 80),
  event_ids uuid[] not null default '{}',
  team_numbers int[] not null default '{}',
  expires_at timestamptz,
  revoked boolean not null default false,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  use_count int not null default 0,
  last_used_at timestamptz,
  check (cardinality(event_ids) > 0 or cardinality(team_numbers) > 0)
);
alter table public.share_codes enable row level security;
drop policy if exists "staff manages share codes" on public.share_codes;
create policy "staff manages share codes" on public.share_codes for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

-- Carry over the old per-event share codes, then remove those columns (runs once, only
-- on a database that still has them)
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'events' and column_name = 'share_code') then
    insert into public.share_codes (code, label, event_ids)
    select share_code, 'Migrated: ' || name, array[id]
    from public.events
    where share_enabled and share_code is not null
    on conflict (code) do nothing;

    alter table public.events drop column share_code, drop column share_enabled;
  end if;
end $$;

-- Upgrade a share_codes table from before multi-event/team codes existed: fold the old
-- single event_id/team_number columns into the new arrays, then drop them. Also backfills
-- created_by/use_count/last_used_at for a table that predates those columns.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'share_codes' and column_name = 'event_id') then
    alter table public.share_codes add column if not exists event_ids uuid[] not null default '{}';
    alter table public.share_codes add column if not exists team_numbers int[] not null default '{}';
    update public.share_codes
       set event_ids    = case when event_id    is not null then array[event_id]    else '{}' end,
           team_numbers = case when team_number is not null then array[team_number] else '{}' end
     where cardinality(event_ids) = 0 and cardinality(team_numbers) = 0;
    alter table public.share_codes drop constraint if exists share_codes_check;
    alter table public.share_codes drop column event_id, drop column team_number;
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'share_codes' and column_name = 'created_by') then
    alter table public.share_codes add column created_by uuid references auth.users(id) on delete set null default auth.uid();
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'share_codes' and column_name = 'use_count') then
    alter table public.share_codes add column use_count int not null default 0;
  end if;
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'share_codes' and column_name = 'last_used_at') then
    alter table public.share_codes add column last_used_at timestamptz;
  end if;
end $$;
alter table public.share_codes drop constraint if exists share_codes_check;
alter table public.share_codes add constraint share_codes_check
  check (cardinality(event_ids) > 0 or cardinality(team_numbers) > 0);

-- Re-point an existing table (created before the 8-digit code format) at the new default.
alter table public.share_codes alter column code set default public.gen_share_code();

-- Anyone on a team can share what they can see (every team sees all scouting data), so codes
-- aren't staff-only any more. owner_team is the creator's team, whose managers can see and
-- revoke the code. A code works only while its creator could still see the data themselves
-- (share_code_creator_ok()), so leaving a team or a ban turns off that person's codes.
alter table public.share_codes add column if not exists owner_team int check (owner_team between 1 and 99999);
alter table public.share_codes alter column owner_team set default public.my_team();

-- Could this account still see shared scouting data? Staff, or on a team. A null creator is a
-- code from before created_by existed, all made by staff. Internal.
create or replace function public.share_code_creator_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_user is null
      or exists (select 1 from public.staff_members s join auth.users u on u.id = s.user_id
                 where s.user_id = p_user and u.email_confirmed_at is not null
                   and (u.banned_until is null or u.banned_until <= now()))
      or exists (select 1 from public.member_team(p_user));
$$;
revoke all on function public.share_code_creator_ok(uuid) from public, anon, authenticated;

-- Limits on codes made by team members (staff have none): it must expire within 90 days, an
-- account holds at most 20 live codes, and afterwards only its label, expiry and revoking can
-- change. Not security definer, so current_user tells an API write ('authenticated') from
-- get_shared_scouting() bumping the use count (runs as the function owner).
create or replace function public.share_codes_guard() returns trigger
language plpgsql set search_path = '' as $$
begin
  if current_user <> 'authenticated' or public.is_staff() then return NEW; end if;
  if (TG_OP = 'INSERT' or NEW.expires_at is distinct from OLD.expires_at)
     and (NEW.expires_at is null or NEW.expires_at > now() + interval '90 days') then
    raise exception 'A share code must expire within 90 days.';
  end if;
  if TG_OP = 'INSERT' then
    NEW.created_by := auth.uid();
    NEW.owner_team := public.my_team();
    NEW.revoked := false;
    NEW.use_count := 0;
    NEW.last_used_at := null;
    NEW.created_at := now();
    if (select count(*) from public.share_codes c
        where c.created_by = auth.uid() and not c.revoked
          and (c.expires_at is null or c.expires_at > now())) >= 20 then
      raise exception 'You have 20 active share codes. Revoke one you no longer need first.';
    end if;
  elsif (NEW.code, NEW.event_ids, NEW.team_numbers, NEW.created_by, NEW.owner_team, NEW.created_at,
         NEW.use_count, NEW.last_used_at)
        is distinct from
        (OLD.code, OLD.event_ids, OLD.team_numbers, OLD.created_by, OLD.owner_team, OLD.created_at,
         OLD.use_count, OLD.last_used_at)
     or (OLD.revoked and not NEW.revoked) then
    raise exception 'Only a share code''s label and expiry can change, or it can be revoked. Make a new code for a different scope.';
  end if;
  return NEW;
end $$;
revoke all on function public.share_codes_guard() from public, anon, authenticated;
drop trigger if exists share_codes_guard on public.share_codes;
create trigger share_codes_guard before insert or update on public.share_codes
  for each row execute function public.share_codes_guard();

-- Members make codes when their team allows it (team_can('share_codes'), every member by
-- default) and see and revoke their own; managers see and revoke all of their team's.
-- Only staff delete codes, so the use history stays.
drop policy if exists "members read share codes"   on public.share_codes;
drop policy if exists "members create share codes" on public.share_codes;
drop policy if exists "members update share codes" on public.share_codes;
create policy "members read share codes" on public.share_codes for select to authenticated
  using (created_by = (select auth.uid())
         or (owner_team = (select public.my_team()) and (select public.is_team_manager())));
create policy "members create share codes" on public.share_codes for insert to authenticated
  with check ((select public.is_student()) and (select public.team_can('share_codes'))
              and created_by = (select auth.uid()) and owner_team = (select public.my_team()));
create policy "members update share codes" on public.share_codes for update to authenticated
  using (created_by = (select auth.uid())
         or (owner_team = (select public.my_team()) and (select public.is_team_manager())))
  with check (created_by = (select auth.uid())
         or (owner_team = (select public.my_team()) and (select public.is_team_manager())));

-- Failed share-code lookups, one row each, read and written only by get_shared_scouting()
-- (section 10) to limit guessing. Rows are pruned as soon as they age out of the window.
create table if not exists public.share_code_attempts (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  attempted_at timestamptz not null default now()
);
create index if not exists share_code_attempts_user_idx
  on public.share_code_attempts (user_id, attempted_at);
alter table public.share_code_attempts enable row level security;
revoke all on public.share_code_attempts from anon, authenticated;


-- =====================================================================
-- 6. Pit entries (one per team per event, owned by the whole team)
--    and validation of every entry against the form fields
-- =====================================================================
create table if not exists public.pit_entries (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  team_number int  not null check (team_number between 1 and 99999),
  data        jsonb not null default '{}'::jsonb,
  scouted_by  uuid not null default auth.uid() references auth.users(id),
  updated_at  timestamptz not null default now(),
  unique (event_id, team_number)
);
alter table public.pit_entries enable row level security;

drop policy if exists "team reads pit"   on public.pit_entries;
drop policy if exists "team adds pit"    on public.pit_entries;
drop policy if exists "team edits pit"   on public.pit_entries;
drop policy if exists "team deletes pit" on public.pit_entries;
create policy "team reads pit" on public.pit_entries for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "team adds pit" on public.pit_entries for insert to authenticated
  with check (((select public.is_staff()) or (select public.is_student())) and scouted_by = auth.uid());
create policy "team edits pit" on public.pit_entries for update to authenticated
  using ((select public.is_staff()) or (select public.is_student()))
  with check ((select public.is_staff()) or (select public.is_student()));
create policy "team deletes pit" on public.pit_entries for delete to authenticated
  using ((select public.is_staff()) or (select public.is_student()));

-- The server decides who last edited a pit entry and when, so neither can be forged through the
-- API. auth.uid() is null for service-role work, which keeps the existing editor.
create or replace function public.stamp_pit_entry() returns trigger
language plpgsql set search_path = '' as $$
begin
  if auth.uid() is not null then new.scouted_by := auth.uid(); end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists stamp_pit_entry on public.pit_entries;
create trigger stamp_pit_entry before insert or update on public.pit_entries
  for each row execute function public.stamp_pit_entry();

-- Every key must belong to the entry's scope. Inactive fields are still accepted,
-- so old entries keep saving, but only as short scalar values (see the first loop below). Active fields are checked for type, range, choices,
-- and required values. 'image' fields hold the uploaded photo's public URL, so
-- they're validated the same way 'text' is (a reasonably short string). 'slider' is
-- validated exactly like 'number' — it's the same stored value, just a different input
-- widget on the Scout page.
--
-- Two key suffixes are accepted without a scout_fields row of their own, since the Scout
-- page generates them automatically rather than staff configuring them per field:
--   <key>__other_note   a free-text note, shown when a 'choice' field with an "Other" option
--                        is set to Other. Valid for any choice field whose options include it.
--   <key>__unsure        boolean, shown instead of the number/slider input when staff enabled
--                         allow_unsure on that field and the scout checked "Unsure".
create or replace function public.validate_data(p_data jsonb, p_scope text) returns void
language plpgsql set search_path = '' as $$
declare
  f record; v jsonb; txt text; k text; base_key text;
  -- The project ref is pinned (any Supabase project would otherwise pass) and the path allows
  -- only the characters uploadImageFields() in scout.html generates. Each path segment must
  -- start with a letter, digit, or underscore, which rules out "..".
  c_photo_url constant text := '^https://nyanwljgsazwuzmnlrcz\.supabase\.co/storage/v1/object/public/scouting-photos(/[A-Za-z0-9_][A-Za-z0-9_.-]*)+$';
begin
  if jsonb_typeof(p_data) <> 'object' then
    raise exception 'Entry data must be an object';
  end if;
  -- Generous for any real form, small enough that nobody can stuff the database through one row
  if octet_length(p_data::text) > 32768 then
    raise exception 'Entry is too large';
  end if;

  for k in select jsonb_object_keys(p_data) loop
    if exists (select 1 from public.scout_fields sf where sf.key = k and sf.scope = p_scope) then
      -- Active fields get full checks below. Retired ones skip those, so bound them here.
      if not exists (select 1 from public.scout_fields sf where sf.key = k and sf.scope = p_scope and sf.active)
         and (jsonb_typeof(p_data -> k) in ('object','array') or char_length(p_data ->> k) > 2000) then
        raise exception 'Entry contains an invalid value for a retired field';
      end if;
      -- A retired photo field still renders as a link, so it keeps the URL rule from the loop below
      if exists (select 1 from public.scout_fields sf where sf.key = k and sf.scope = p_scope and not sf.active and sf.field_type = 'image')
         and jsonb_typeof(p_data -> k) <> 'null'
         and (jsonb_typeof(p_data -> k) <> 'string' or p_data ->> k !~ c_photo_url) then
        raise exception 'Entry contains an invalid value for a retired field';
      end if;
      continue;
    end if;
    if k like '%\_\_other\_note' escape '\' then
      base_key := left(k, length(k) - length('__other_note'));
      if not exists (select 1 from public.scout_fields sf where sf.key = base_key and sf.scope = p_scope
                       and sf.field_type = 'choice' and 'Other' = any (sf.options)) then
        raise exception 'Entry contains a field that is not part of this form';
      end if;
      if jsonb_typeof(p_data -> k) <> 'string' or char_length(p_data ->> k) > 300 then
        raise exception 'Note for % is too long', base_key;
      end if;
    elsif k like '%\_\_unsure' escape '\' then
      base_key := left(k, length(k) - length('__unsure'));
      if not exists (select 1 from public.scout_fields sf where sf.key = base_key and sf.scope = p_scope
                       and sf.field_type in ('number','slider') and sf.allow_unsure) then
        raise exception 'Entry contains a field that is not part of this form';
      end if;
      if jsonb_typeof(p_data -> k) <> 'boolean' then raise exception '% must be yes or no', base_key; end if;
    else
      raise exception 'Entry contains a field that is not part of this form';
    end if;
  end loop;

  for f in select * from public.scout_fields where scope = p_scope and active loop
    -- A field marked "Unsure" via its __unsure companion key is deliberately left blank, so it
    -- skips the usual required/type checks. It must really be blank, or this skip would let any
    -- value past them.
    if f.field_type in ('number','slider') and f.allow_unsure
       and coalesce((p_data ->> (f.key || '__unsure'))::boolean, false) then
      if jsonb_typeof(p_data -> f.key) <> 'null' then
        raise exception '% can''t be both Unsure and answered', f.label;
      end if;
      continue;
    end if;

    v := p_data -> f.key;
    if v is null or jsonb_typeof(v) = 'null' then
      if f.required then raise exception 'Missing required field: %', f.label; end if;
      continue;
    end if;
    txt := v #>> '{}';

    if f.field_type in ('number','slider') then
      if jsonb_typeof(v) <> 'number' then raise exception '% must be a number', f.label; end if;
      if f.min_value is not null and txt::numeric < f.min_value then raise exception '% is too low', f.label; end if;
      if f.max_value is not null and txt::numeric > f.max_value then raise exception '% is too high', f.label; end if;
    elsif f.field_type = 'boolean' then
      if jsonb_typeof(v) <> 'boolean' then raise exception '% must be yes or no', f.label; end if;
    elsif f.field_type = 'choice' then
      if f.options is null or not (txt = any (f.options)) then raise exception '% has an invalid choice', f.label; end if;
    elsif f.field_type = 'text' then
      if jsonb_typeof(v) <> 'string' or char_length(txt) > 500 then raise exception '% is too long', f.label; end if;
    elsif f.field_type = 'image' then
      -- Must actually be a public URL into our own scouting-photos bucket, not an arbitrary
      -- string. This is the gate that keeps a crafted data payload (e.g. sent straight to the
      -- REST API, bypassing the site's own upload flow) from ever storing attacker-controlled
      -- text in a field that scout.html/query.html later render into an <img src="..."> / <a href="...">.
      if jsonb_typeof(v) <> 'string' or char_length(txt) > 2000 or txt !~ c_photo_url
      then raise exception '% must be a photo uploaded through the scouting-photos bucket', f.label; end if;
    end if;
  end loop;
end $$;

create or replace function public.validate_entry() returns trigger
language plpgsql set search_path = '' as $$
begin
  -- Fixing a team or match number shouldn't fail because form rules changed after this was saved
  if tg_op = 'UPDATE' and new.data = old.data then return new; end if;
  perform public.validate_data(new.data, 'match');
  return new;
end $$;

drop trigger if exists validate_entry on public.scouting_entries;
create trigger validate_entry before insert or update on public.scouting_entries
  for each row execute function public.validate_entry();

create or replace function public.validate_pit_entry() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and new.data = old.data then return new; end if;
  perform public.validate_data(new.data, 'pit');
  return new;
end $$;

drop trigger if exists validate_pit_entry on public.pit_entries;
create trigger validate_pit_entry before insert or update on public.pit_entries
  for each row execute function public.validate_pit_entry();


-- =====================================================================
-- 7. Policies for events and match entries
--    Throughout this file, "(select public.is_staff())" rather than a bare call makes Postgres
--    run the check once per query instead of once per row. Keep that form in new policies.
-- =====================================================================
alter table public.events enable row level security;
alter table public.scouting_entries enable row level security;

drop policy if exists "staff and students read events" on public.events;
drop policy if exists "staff add events"               on public.events;
drop policy if exists "staff edit events"              on public.events;
drop policy if exists "staff deletes events"           on public.events;
create policy "staff and students read events" on public.events for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "staff add events" on public.events for insert to authenticated
  with check ((select public.is_staff()));
create policy "staff edit events" on public.events for update to authenticated
  using ((select public.is_staff()));
create policy "staff deletes events" on public.events for delete to authenticated
  using ((select public.is_staff()));

drop policy if exists "staff and students read entries" on public.scouting_entries;
drop policy if exists "team adds entries"               on public.scouting_entries;
drop policy if exists "team edits own entries"          on public.scouting_entries;
drop policy if exists "staff edits any entry"           on public.scouting_entries;
drop policy if exists "team deletes own entries"        on public.scouting_entries;
drop policy if exists "staff deletes any entry"         on public.scouting_entries;
create policy "staff and students read entries" on public.scouting_entries for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "team adds entries" on public.scouting_entries for insert to authenticated
  with check (((select public.is_staff()) or (select public.is_student())) and scouted_by = auth.uid());
create policy "team edits own entries" on public.scouting_entries for update to authenticated
  using (((select public.is_staff()) or (select public.is_student())) and scouted_by = auth.uid())
  with check (scouted_by = auth.uid());
create policy "staff edits any entry" on public.scouting_entries for update to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
create policy "team deletes own entries" on public.scouting_entries for delete to authenticated
  using (((select public.is_staff()) or (select public.is_student())) and scouted_by = auth.uid());
create policy "staff deletes any entry" on public.scouting_entries for delete to authenticated
  using ((select public.is_staff()));


-- =====================================================================
-- 8. Official match data (FRC Events + The Blue Alliance)
--    The official-sync Edge Function writes these rows with the service
--    role. Staff and students can read them; nobody can write through
--    the API.
--
--    match_key is the same on both sources, so rows line up:
--      qm12   = Qualification match 12
--      sf8m1  = Playoff match 8 (double-elimination set 8)
--      f1m2   = Finals match 2 (playoff matches 14-16 on the FRC site)
-- =====================================================================
create table if not exists public.official_matches (
  id             bigint generated always as identity primary key,
  event_id       uuid not null references public.events(id) on delete cascade,
  source         text not null check (source in ('frc','tba')),
  match_key      text not null,
  comp_level     text not null check (comp_level in ('qm','sf','f')),
  set_number     int  not null default 1,
  match_number   int  not null,
  played_at      timestamptz,
  red_teams      int[] not null,
  blue_teams     int[] not null,
  red_score      int,
  blue_score     int,
  red_breakdown  jsonb,   -- full per-alliance score breakdown exactly as the source sent it
  blue_breakdown jsonb,
  updated_at     timestamptz not null default now(),
  unique (event_id, source, match_key)
);
create index if not exists official_matches_event_idx  on public.official_matches (event_id, match_key);
create index if not exists official_matches_lookup_idx on public.official_matches (event_id, comp_level, match_number);
-- Find a team's matches without reading every row (official_match_teams_for(), and the
-- "red_teams contains" filters pages send to official_matches_combined).
create index if not exists official_matches_red_teams_idx  on public.official_matches using gin (red_teams);
create index if not exists official_matches_blue_teams_idx on public.official_matches using gin (blue_teams);
-- Everything but the score breakdowns, so whole-table totals (ratings, counts) can read this
-- small index instead of the much larger table rows that hold the breakdown JSON.
create index if not exists official_matches_slim_idx on public.official_matches (event_id, match_key, source)
  include (comp_level, set_number, match_number, played_at, red_teams, blue_teams, red_score, blue_score);
alter table public.official_matches enable row level security;

drop policy if exists "team reads official matches" on public.official_matches;
create policy "team reads official matches" on public.official_matches for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));

-- 8a. One row per match. FRC Events is the authority for scores; TBA fills in when FRC has
--     nothing yet. sources shows where the row came from; scores_agree is false if the two
--     sources disagree.
--     Built from a "primary" row p (the FRC row, or the TBA row when FRC has none) plus the
--     other source's row s. Event, match and team columns come straight from p, so filters on
--     them (event_id, comp_level, red_teams contains ...) use the indexes above instead of
--     joining the whole table first.
create or replace view public.official_matches_combined with (security_invoker = true) as
select
  p.event_id,
  p.match_key,
  p.comp_level,
  p.set_number,
  p.match_number,
  coalesce(p.played_at, s.played_at)       as played_at,
  p.red_teams,
  p.blue_teams,
  coalesce(p.red_score, s.red_score)       as red_score,
  coalesce(p.blue_score, s.blue_score)     as blue_score,
  coalesce(s.red_breakdown, p.red_breakdown)   as red_breakdown,    -- s is the TBA row when both exist
  coalesce(s.blue_breakdown, p.blue_breakdown) as blue_breakdown,
  case when s.id is not null then 'frc+tba' else p.source end as sources,
  case when s.id is not null
       then p.red_score is not distinct from s.red_score and p.blue_score is not distinct from s.blue_score
       end as scores_agree
from public.official_matches p
left join public.official_matches s
  on s.event_id = p.event_id and s.match_key = p.match_key and s.source <> p.source
where p.source = 'frc' or s.id is null;

-- 8b. One row per team per PLAYED match: the shape the team rating reads.
create or replace view public.official_team_matches with (security_invoker = true) as
select m.event_id, m.match_key, m.comp_level, m.set_number, m.match_number, m.played_at,
       'red'::text as alliance, x.team as team_number,
       m.red_score as alliance_score, m.blue_score as opponent_score,
       m.red_breakdown as breakdown,
       m.red_score > m.blue_score  as won,
       m.red_score = m.blue_score  as tied,
       m.sources
from public.official_matches_combined m
cross join lateral unnest(m.red_teams) as x(team)
where m.red_score is not null and m.blue_score is not null and x.team is not null
union all
select m.event_id, m.match_key, m.comp_level, m.set_number, m.match_number, m.played_at,
       'blue', x.team,
       m.blue_score, m.red_score, m.blue_breakdown,
       m.blue_score > m.red_score,
       m.blue_score = m.red_score,
       m.sources
from public.official_matches_combined m
cross join lateral unnest(m.blue_teams) as x(team)
where m.red_score is not null and m.blue_score is not null and x.team is not null;

-- 8c. One row per team per match INCLUDING matches not played yet (scores are null).
--     The Team Database page reads this one, so a team's upcoming schedule shows too.
--     Prefers a row that has a score, then FRC over TBA.
create or replace view public.official_match_teams
with (security_invoker = true) as
select distinct on (m.event_id, m.match_key, t.team_number)
  m.event_id,
  m.match_key,
  m.comp_level,
  m.set_number,
  m.match_number,
  m.played_at,
  m.source,
  t.team_number,
  t.alliance,
  t.station,
  case t.alliance when 'red' then m.red_score  else m.blue_score end as alliance_score,
  case t.alliance when 'red' then m.blue_score else m.red_score  end as opponent_score,
  case t.alliance when 'red' then m.red_breakdown else m.blue_breakdown end as breakdown
from public.official_matches m
cross join lateral (
  select u.team as team_number, 'red'::text as alliance, u.ord::int as station
    from unnest(m.red_teams) with ordinality as u(team, ord)
  union all
  select u.team, 'blue', u.ord::int
    from unnest(m.blue_teams) with ordinality as u(team, ord)
) t
where t.team_number is not null
order by m.event_id, m.match_key, t.team_number,
         (m.red_score is not null) desc, (m.source = 'frc') desc;

-- 8c2. official_match_teams for just the given teams. Filtering the view by team_number
--      still unpacks every match in the table first; this finds the teams' matches through
--      the red/blue team indexes. Same columns and rules as the view.
--      Security definer with the same access check as the table's policy: under row-level
--      security Postgres won't use an index for the array operators (&&, @>, not leakproof),
--      so running as the caller would read every match and time out.
create or replace function public.official_match_teams_for(p_teams int[])
returns setof public.official_match_teams
language sql stable security definer set search_path = '' as $$
  select distinct on (m.event_id, m.match_key, t.team_number)
    m.event_id, m.match_key, m.comp_level, m.set_number, m.match_number, m.played_at, m.source,
    t.team_number, t.alliance, t.station,
    case t.alliance when 'red' then m.red_score  else m.blue_score end,
    case t.alliance when 'red' then m.blue_score else m.red_score  end,
    case t.alliance when 'red' then m.red_breakdown else m.blue_breakdown end
  from public.official_matches m
  cross join lateral (
    select u.team as team_number, 'red'::text as alliance, u.ord::int as station
      from unnest(m.red_teams) with ordinality as u(team, ord)
    union all
    select u.team, 'blue', u.ord::int
      from unnest(m.blue_teams) with ordinality as u(team, ord)
  ) t
  where (m.red_teams && p_teams or m.blue_teams && p_teams)
    and t.team_number = any(p_teams)
    and ((select public.is_staff()) or (select public.is_student()))
  order by m.event_id, m.match_key, t.team_number,
           (m.red_score is not null) desc, (m.source = 'frc') desc;
$$;

-- 8c3. Who was on each alliance in every match the given teams played (official_matches_combined
--      rows), for the Team Database's partner and opponent columns. Security definer for the
--      same index reason as 8c2.
create or replace function public.official_lineups_for(p_teams int[])
returns table (event_id uuid, match_key text, red_teams int[], blue_teams int[],
               sources text, scores_agree boolean)
language sql stable security definer set search_path = '' as $$
  select c.event_id, c.match_key, c.red_teams, c.blue_teams, c.sources, c.scores_agree
  from public.official_matches_combined c
  where (c.red_teams && p_teams or c.blue_teams && p_teams)
    and ((select public.is_staff()) or (select public.is_student()));
$$;

-- 8d. Per-team official summary (matches played, wins, average alliance score)
--     for the Team Database list. This computes it from every match; pages read the cached
--     copy through team_official_summary() (section 9, "official rating cache").
create or replace function public.official_summary_compute()
returns table (team_number int, matches int, wins int, avg_alliance_score numeric)
language sql stable security definer set search_path = '' as $$
  select o.team_number,
         count(*)::int,
         count(*) filter (where o.alliance_score > o.opponent_score)::int,
         round(avg(o.alliance_score), 2)
  from public.official_match_teams o
  where o.alliance_score is not null
  group by o.team_number;
$$;


-- =====================================================================
-- 8e. Test teams
--
--    Staff can tag a team number as "test" from the Staff Portal (e.g. a
--    team made up to try out the Scout form, or a dummy number used while
--    debugging). This doesn't hide or delete anything that team scouted —
--    it just tells the Team Database to keep that team out of the
--    "rated teams" comparison pool (see scoutGradeFor/officialGradeFor in
--    query.html) and to badge it clearly, so test data never skews a real
--    team's percentile or gets mistaken for a real opponent.
-- =====================================================================
create table if not exists public.test_teams (
  team_number int primary key check (team_number between 1 and 99999),
  note text check (char_length(note) <= 200),
  added_by uuid references auth.users(id) on delete set null,
  added_at timestamptz not null default now()
);
alter table public.test_teams enable row level security;

drop policy if exists "team reads test teams"   on public.test_teams;
drop policy if exists "staff manages test teams" on public.test_teams;
create policy "team reads test teams" on public.test_teams for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "staff manages test teams" on public.test_teams for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));


-- =====================================================================
-- 8f. Team info (names + logos)
--
--    Lets staff attach a display name and a logo to any team number (ours,
--    an opponent, anyone) from the Staff Portal. Purely cosmetic — shown on
--    the team's card in the Team Database (query.html) and in the team
--    list there — it has no effect on ratings or scouting data.
--    logo_url is either a pasted image link or a file staff uploaded to the
--    "team-logos" Storage bucket (section 8g); either way it's just stored
--    as a URL and rendered with <img>.
-- =====================================================================
create table if not exists public.team_info (
  team_number int primary key check (team_number between 1 and 99999),
  team_name   text check (char_length(team_name) <= 100),
  logo_url    text check (char_length(logo_url) <= 500),
  updated_by  uuid references auth.users(id) on delete set null,
  updated_at  timestamptz not null default now()
);
alter table public.team_info enable row level security;

-- tba_name and tba_logo_url are filled automatically by the team-names Edge Function
-- (supabase/functions/team-names, deploy with: supabase functions deploy team-names --no-verify-jwt)
-- from The Blue Alliance: the team's nickname ('' means TBA has none) and its FIRST avatar, saved
-- in the team-logos bucket under tba/. A page asks for a team never looked up, or not looked up
-- in 30 days (tba_checked_at). A name or logo staff set wins. Pages read display_name and
-- display_logo, so they never repeat that rule.
alter table public.team_info add column if not exists tba_name text check (char_length(tba_name) <= 100);
alter table public.team_info add column if not exists tba_logo_url text
  check (char_length(tba_logo_url) <= 500 and tba_logo_url ~ '^https://[^[:space:]"<>]+$');
alter table public.team_info add column if not exists tba_checked_at timestamptz;
alter table public.team_info add column if not exists display_name text
  generated always as (coalesce(team_name, nullif(tba_name, ''))) stored;
alter table public.team_info add column if not exists display_logo text
  generated always as (coalesce(logo_url, tba_logo_url)) stored;

-- Logos are pasted links or uploads, so require https. "not valid" leaves existing rows alone.
alter table public.team_info drop constraint if exists team_info_logo_https;
alter table public.team_info add constraint team_info_logo_https
  check (logo_url is null or logo_url ~ '^https://[^[:space:]"<>]+$') not valid;

drop policy if exists "team reads team info"   on public.team_info;
drop policy if exists "staff manages team info" on public.team_info;
create policy "team reads team info" on public.team_info for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "staff manages team info" on public.team_info for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));


-- =====================================================================
-- 8g. Storage: team logos
--
--    Backs the logo upload under Team names and logos on the Staff Portal's Teams tab (section 8f).
--    Public, like scouting-photos, so a saved logo_url renders directly.
--    Path convention the site uses: <team_number>-<timestamp>.<ext>
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('team-logos', 'team-logos', true, 2097152,
        array['image/jpeg','image/png','image/webp','image/svg+xml'])
on conflict (id) do update set
  public = true, file_size_limit = 2097152,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/svg+xml'];

drop policy if exists "staff uploads team logos" on storage.objects;
drop policy if exists "staff replaces team logos" on storage.objects;
drop policy if exists "anyone views team logos" on storage.objects;
drop policy if exists "staff lists team logos" on storage.objects;
drop policy if exists "staff deletes team logos" on storage.objects;

create policy "staff uploads team logos" on storage.objects for insert to authenticated
  with check (bucket_id = 'team-logos' and (select public.is_staff()));
create policy "staff replaces team logos" on storage.objects for update to authenticated
  using (bucket_id = 'team-logos' and (select public.is_staff()))
  with check (bucket_id = 'team-logos' and (select public.is_staff()));
-- Public URLs in a public bucket are served without this policy. It only controls listing the
-- bucket's contents through the API, which upload's upsert also needs, so keep it to staff.
create policy "staff lists team logos" on storage.objects for select to authenticated
  using (bucket_id = 'team-logos' and (select public.is_staff()));
create policy "staff deletes team logos" on storage.objects for delete to authenticated
  using (bucket_id = 'team-logos' and (select public.is_staff()));


-- =====================================================================
-- 8h. Playoff picks
--
--    The alliances entered on the Playoff Selection page (playoffs.html) as
--    they form at an event. One row per filled spot, so a pick or removal is
--    a single-row write. Slot 1 is the captain, then 1st, 2nd and 3rd pick.
--    Staff write and the whole team reads. The unique key means a team can't
--    be on two alliances, even if two people pick it at the same moment.
-- =====================================================================
create table if not exists public.playoff_picks (
  event_id        uuid not null references public.events(id) on delete cascade,
  alliance_number int  not null check (alliance_number between 1 and 8),
  slot            int  not null check (slot between 1 and 4),
  team_number     int  not null check (team_number between 1 and 99999),
  primary key (event_id, alliance_number, slot),
  unique (event_id, team_number)
);
alter table public.playoff_picks enable row level security;
-- 'official' rows were copied from FRC Events or TBA by the official-alliances Edge Function
alter table public.playoff_picks add column if not exists source text not null default 'manual'
  check (source in ('manual', 'official'));

drop policy if exists "team reads playoff picks"    on public.playoff_picks;
drop policy if exists "staff manages playoff picks" on public.playoff_picks;
create policy "team reads playoff picks" on public.playoff_picks for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "staff manages playoff picks" on public.playoff_picks for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));

-- Copies an event's official alliances into playoff_picks, so Playoff Selection and the Playoff
-- Bracket follow them. Called only by the official-alliances Edge Function (service role) after
-- each sync. p_alliances is [{ "number": 1, "teams": [captain, 1st, 2nd, 3rd?] }, ...].
-- Only a finished selection is applied (every alliance listed has at least 3 teams), so a
-- half-published list never wipes picks staff are entering live. Nothing is written when the
-- picks already match, so a sync every 2 minutes doesn't fill the audit log.
create or replace function public.official_set_alliances(p_event uuid, p_alliances jsonb)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_rows jsonb;
  v_now  jsonb;
begin
  if jsonb_typeof(p_alliances) <> 'array' or jsonb_array_length(p_alliances) = 0 then
    return 'none';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_alliances) a
    where (a ->> 'number')::int not between 1 and 8
       or jsonb_array_length(a -> 'teams') not between 3 and 4
  ) then
    return 'incomplete';
  end if;
  -- One row per spot, in the same shape as the current picks, to compare
  select coalesce(jsonb_agg(jsonb_build_array((a ->> 'number')::int, t.slot::int, t.team::int)
                            order by (a ->> 'number')::int, t.slot), '[]'::jsonb)
    into v_rows
    from jsonb_array_elements(p_alliances) a
    cross join lateral jsonb_array_elements_text(a -> 'teams') with ordinality as t(team, slot);
  select coalesce(jsonb_agg(jsonb_build_array(alliance_number, slot, team_number)
                            order by alliance_number, slot), '[]'::jsonb)
    into v_now
    from public.playoff_picks where event_id = p_event;
  if v_rows = v_now then
    update public.playoff_picks set source = 'official' where event_id = p_event and source <> 'official';
    return 'unchanged';
  end if;
  delete from public.playoff_picks where event_id = p_event;
  insert into public.playoff_picks (event_id, alliance_number, slot, team_number, source)
    select p_event, (r ->> 0)::int, (r ->> 1)::int, (r ->> 2)::int, 'official'
    from jsonb_array_elements(v_rows) r;
  return 'updated';
end $$;
revoke all on function public.official_set_alliances(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.official_set_alliances(uuid, jsonb) to service_role;

-- Alliance size for the event: 3, or 4 with a third round of picks. Blank means the usual rule
-- (4 at district championships and the FIRST Championship), so only an off-season that changes
-- format needs setting. Staff set it with the toggle on Playoff Selection.
alter table public.events add column if not exists alliance_size int check (alliance_size in (3, 4));

-- The Playoff Bracket works out every result from the official sync. Two things it can't know:
--   playoff_tiebreaks  who won a match the official scores show as tied (staff enter it from the
--                      bracket after the tiebreaker). match_key is the exact match, e.g. sf5m1.
--   playoff_lineups    on a 4-team alliance, which team sits out a match, so the captain plays
--                      with the other two. Keyed by bracket match: sf5, or f1m2 for a finals game.
--                      No row means the 3rd pick sits out. Once a match is played, the official
--                      line-up is shown instead.
create table if not exists public.playoff_tiebreaks (
  event_id        uuid not null references public.events(id) on delete cascade,
  match_key       text not null check (match_key ~ '^(sf[0-9]{1,2}m[0-9]{1,2}|f1m[0-9]{1,2})$'),
  winner_alliance int  not null check (winner_alliance between 1 and 8),
  primary key (event_id, match_key)
);
create table if not exists public.playoff_lineups (
  event_id        uuid not null references public.events(id) on delete cascade,
  match_key       text not null check (match_key ~ '^(sf[0-9]{1,2}|f1m[0-9]{1,2})$'),
  alliance_number int  not null check (alliance_number between 1 and 8),
  sits_out        int  not null check (sits_out between 1 and 99999),
  primary key (event_id, match_key, alliance_number)
);
alter table public.playoff_tiebreaks enable row level security;
alter table public.playoff_lineups   enable row level security;

drop policy if exists "team reads playoff tiebreaks"    on public.playoff_tiebreaks;
drop policy if exists "staff manages playoff tiebreaks" on public.playoff_tiebreaks;
drop policy if exists "team reads playoff lineups"      on public.playoff_lineups;
drop policy if exists "staff manages playoff lineups"   on public.playoff_lineups;
create policy "team reads playoff tiebreaks" on public.playoff_tiebreaks for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "staff manages playoff tiebreaks" on public.playoff_tiebreaks for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));
create policy "team reads playoff lineups" on public.playoff_lineups for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "staff manages playoff lineups" on public.playoff_lineups for all to authenticated
  using ((select public.is_staff())) with check ((select public.is_staff()));


-- =====================================================================
-- 8i. Match schedule edits (matches.html)
--
--    The Our Matches page reads each event's schedule from the official
--    sync. A row here adds a match the sync doesn't have yet, or replaces
--    the line-up of one it does (same match_key, e.g. qm12). Deleting the
--    row goes back to the official version. Any team member can edit.
-- =====================================================================
create table if not exists public.match_schedule (
  event_id     uuid not null references public.events(id) on delete cascade,
  match_key    text not null check (match_key ~ '^(qm[0-9]{1,3}|sf[0-9]{1,2}m[0-9]{1,2}|f1m[0-9]{1,2})$'),
  red_teams    int[] not null check (cardinality(red_teams) between 1 and 3 and array_position(red_teams, null) is null
                                     and 1 <= all(red_teams) and 99999 >= all(red_teams)),
  blue_teams   int[] not null check (cardinality(blue_teams) between 1 and 3 and array_position(blue_teams, null) is null
                                     and 1 <= all(blue_teams) and 99999 >= all(blue_teams)),
  scheduled_at timestamptz,
  updated_by   uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at   timestamptz not null default now(),
  primary key (event_id, match_key)
);
alter table public.match_schedule enable row level security;

drop policy if exists "team reads match schedule"   on public.match_schedule;
drop policy if exists "team adds match schedule"    on public.match_schedule;
drop policy if exists "team edits match schedule"   on public.match_schedule;
drop policy if exists "team deletes match schedule" on public.match_schedule;
create policy "team reads match schedule" on public.match_schedule for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "team adds match schedule" on public.match_schedule for insert to authenticated
  with check (((select public.is_staff()) or (select public.is_student())) and updated_by = auth.uid());
create policy "team edits match schedule" on public.match_schedule for update to authenticated
  using ((select public.is_staff()) or (select public.is_student()))
  with check (updated_by = auth.uid());
create policy "team deletes match schedule" on public.match_schedule for delete to authenticated
  using ((select public.is_staff()) or (select public.is_student()));


-- =====================================================================
-- 8j. Vision data and match flags
--
--    vision_matches / vision_robots are written only by the vision worker
--    (vision/ in this repo), which runs on a team laptop and connects with the
--    service role key. It reads match video, the on-screen scoreboard, and
--    where each robot drove. Nobody writes these through the normal API.
--    Vision numbers are estimates and stay a separate source: no rating reads them.
--
--    match_flag_reviews records what a team member decided about a flag on the
--    Match Flags page (flags.html): it looks fine, it was fixed, or it needs a
--    rescout. The flags themselves are worked out on that page from the data
--    already here. team_number 0 means a flag about the whole match or alliance.
-- =====================================================================
create table if not exists public.vision_matches (
  event_id         uuid not null references public.events(id) on delete cascade,
  match_key        text not null check (match_key ~ '^(qm[0-9]{1,3}|sf[0-9]{1,2}m[0-9]{1,2}|f1m[0-9]{1,2})$'),
  status           text not null check (status in ('ok', 'partial', 'failed')),
  video_url        text check (char_length(video_url) <= 500),
  score_timeline   jsonb,      -- [[seconds into the match, red score, blue score], ...]
  final_red        int,
  final_blue       int,
  matches_official boolean,    -- false when the scoreboard read doesn't match the official final score
  wide_shot_share  numeric check (wide_shot_share between 0 and 1),   -- share of the match the field was in view
  model_version    text check (char_length(model_version) <= 80),
  notes            text check (char_length(notes) <= 500),
  processed_at     timestamptz not null default now(),
  primary key (event_id, match_key)
);
create table if not exists public.vision_robots (
  event_id    uuid not null,
  match_key   text not null,
  team_number int  not null check (team_number between 1 and 99999),
  alliance    text not null check (alliance in ('red', 'blue')),
  data        jsonb not null default '{}'::jsonb,   -- per-robot metrics, see vision/README.md
  confidence  numeric not null check (confidence between 0 and 1),
  primary key (event_id, match_key, team_number),
  foreign key (event_id, match_key) references public.vision_matches(event_id, match_key) on delete cascade
);
create index if not exists vision_robots_team_idx on public.vision_robots (team_number);
alter table public.vision_matches enable row level security;
alter table public.vision_robots  enable row level security;

drop policy if exists "team reads vision matches" on public.vision_matches;
drop policy if exists "team reads vision robots"  on public.vision_robots;
create policy "team reads vision matches" on public.vision_matches for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "team reads vision robots" on public.vision_robots for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));

create table if not exists public.match_flag_reviews (
  id          bigint generated always as identity primary key,
  event_id    uuid not null references public.events(id) on delete cascade,
  match_key   text not null check (char_length(match_key) <= 12),
  team_number int  not null default 0 check (team_number between 0 and 99999),
  flag_type   text not null check (flag_type ~ '^[a-z_]{1,40}$'),
  status      text not null check (status in ('ok', 'fixed', 'rescout')),
  note        text check (char_length(note) <= 300),
  reviewed_by uuid default auth.uid() references auth.users(id) on delete set null,
  reviewed_at timestamptz not null default now(),
  unique (event_id, match_key, team_number, flag_type)
);
alter table public.match_flag_reviews enable row level security;

drop policy if exists "team reads flag reviews"   on public.match_flag_reviews;
drop policy if exists "team adds flag reviews"    on public.match_flag_reviews;
drop policy if exists "team edits flag reviews"   on public.match_flag_reviews;
drop policy if exists "team deletes flag reviews" on public.match_flag_reviews;
create policy "team reads flag reviews" on public.match_flag_reviews for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));
create policy "team adds flag reviews" on public.match_flag_reviews for insert to authenticated
  with check (((select public.is_staff()) or (select public.is_student())) and reviewed_by = auth.uid());
create policy "team edits flag reviews" on public.match_flag_reviews for update to authenticated
  using ((select public.is_staff()) or (select public.is_student()))
  with check (reviewed_by = auth.uid());
create policy "team deletes flag reviews" on public.match_flag_reviews for delete to authenticated
  using ((select public.is_staff()) or (select public.is_student()));


-- =====================================================================
-- 8k. Match strategy plans (strategy.html)
--
--    One plan per match: where each robot starts and what was drawn on the
--    field map. plan is the page's own JSON ({ teams, robots, strokes }); the
--    database only checks that it's an object of a sane size. Each team has its
--    own plans. Its members can make, change or remove one (unless a manager kept
--    that to managers), and the last save wins. Plans stay after the match is
--    played, so the team can review the ones that worked.
-- =====================================================================
create table if not exists public.match_strategies (
  event_id   uuid not null references public.events(id) on delete cascade,
  match_key  text not null check (match_key ~ '^(qm[0-9]{1,3}|sf[0-9]{1,2}m[0-9]{1,2}|f1m[0-9]{1,2})$'),
  plan       jsonb not null check (jsonb_typeof(plan) = 'object' and octet_length(plan::text) <= 300000),
  updated_by uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (event_id, match_key)
);
alter table public.match_strategies enable row level security;

-- Each team's own plans (section 3b). Rows from before teams existed are the home team's. A page
-- that doesn't send owner_team gets the saver's team. The (owner_team, event_id, match_key) key
-- replaces the old primary key in step 2 (section 16b), once every live page sends owner_team.
alter table public.match_strategies add column if not exists owner_team int;
update public.match_strategies set owner_team = public.home_team() where owner_team is null;
alter table public.match_strategies alter column owner_team set default public.my_team();
alter table public.match_strategies alter column owner_team set not null;
do $$
begin
  if not exists (select 1 from pg_index i where i.indrelid = 'public.match_strategies'::regclass and i.indisunique
                 and pg_get_indexdef(i.indexrelid) like '%(owner_team, event_id, match_key)%') then
    create unique index match_strategies_team_key on public.match_strategies (owner_team, event_id, match_key);
  end if;
end $$;

drop policy if exists "team reads match strategies"   on public.match_strategies;
drop policy if exists "team adds match strategies"    on public.match_strategies;
drop policy if exists "team edits match strategies"   on public.match_strategies;
drop policy if exists "team deletes match strategies" on public.match_strategies;
create policy "team reads match strategies" on public.match_strategies for select to authenticated
  using (owner_team = (select public.my_team()));
create policy "team adds match strategies" on public.match_strategies for insert to authenticated
  with check (owner_team = (select public.my_team()) and (select public.team_can('strategy')) and updated_by = auth.uid());
create policy "team edits match strategies" on public.match_strategies for update to authenticated
  using (owner_team = (select public.my_team()) and (select public.team_can('strategy')))
  with check (owner_team = (select public.my_team()) and updated_by = auth.uid());
create policy "team deletes match strategies" on public.match_strategies for delete to authenticated
  using (owner_team = (select public.my_team()) and (select public.team_can('strategy')));

-- Alliance plans. For a match a team plays in, the plan belongs to its alliance, not to one team:
-- one plan per alliance per match, shared by the three teams on it (each team's members who may
-- change plans, per team_can('strategy')). The other alliance never sees it. match_strategies
-- above keeps a team's private plans for matches it isn't in.
--
-- Who is on an alliance comes from the official line-up. A match_schedule edit (which any team
-- member can make) only counts for a match the official schedule doesn't have yet, so nobody can
-- edit the schedule to put their team on someone else's alliance and read its plan.
create table if not exists public.alliance_strategies (
  event_id   uuid not null references public.events(id) on delete cascade,
  match_key  text not null check (match_key ~ '^(qm[0-9]{1,3}|sf[0-9]{1,2}m[0-9]{1,2}|f1m[0-9]{1,2})$'),
  alliance   text not null check (alliance in ('red', 'blue')),
  plan       jsonb not null check (jsonb_typeof(plan) = 'object' and octet_length(plan::text) <= 300000),
  updated_by uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (event_id, match_key, alliance)
);
alter table public.alliance_strategies enable row level security;

-- Which alliance a team is on in a match ('red', 'blue', or null). Internal.
create or replace function public.match_alliance(p_event uuid, p_match text, p_team int) returns text
language sql stable security definer set search_path = '' as $$
  select case when p_team = any(l.red) then 'red' when p_team = any(l.blue) then 'blue' end
  from (
    select case when o.match_key is not null then o.red_teams  else e.red_teams  end as red,
           case when o.match_key is not null then o.blue_teams else e.blue_teams end as blue
    from (select 1) x
    left join public.official_matches_combined o
      on o.event_id = p_event and o.match_key = p_match and cardinality(o.red_teams) > 0
    left join public.match_schedule e on e.event_id = p_event and e.match_key = p_match
  ) l;
$$;
revoke all on function public.match_alliance(uuid, text, int) from public, anon, authenticated;

-- The caller's alliance in a match, through their team
create or replace function public.my_alliance(p_event uuid, p_match text) returns text
language sql stable security definer set search_path = '' as $$
  select public.match_alliance(p_event, p_match, public.my_team());
$$;

drop policy if exists "alliance reads its plan"    on public.alliance_strategies;
drop policy if exists "alliance adds its plan"     on public.alliance_strategies;
drop policy if exists "alliance edits its plan"    on public.alliance_strategies;
drop policy if exists "alliance deletes its plan"  on public.alliance_strategies;
create policy "alliance reads its plan" on public.alliance_strategies for select to authenticated
  using (alliance = public.my_alliance(event_id, match_key));
create policy "alliance adds its plan" on public.alliance_strategies for insert to authenticated
  with check (alliance = public.my_alliance(event_id, match_key) and (select public.team_can('strategy'))
              and updated_by = auth.uid());
create policy "alliance edits its plan" on public.alliance_strategies for update to authenticated
  using (alliance = public.my_alliance(event_id, match_key) and (select public.team_can('strategy')))
  with check (alliance = public.my_alliance(event_id, match_key) and updated_by = auth.uid());
create policy "alliance deletes its plan" on public.alliance_strategies for delete to authenticated
  using (alliance = public.my_alliance(event_id, match_key) and (select public.team_can('strategy')));

-- Copy each team's plans for its own matches onto its alliance (safe to re-run: a plan already
-- there wins). The stable release still saves to match_strategies until it has this change.
insert into public.alliance_strategies (event_id, match_key, alliance, plan, updated_by, updated_at)
select ms.event_id, ms.match_key, a.alliance, ms.plan, ms.updated_by, ms.updated_at
from public.match_strategies ms
cross join lateral (select public.match_alliance(ms.event_id, ms.match_key, ms.owner_team) as alliance) a
where a.alliance is not null
on conflict (event_id, match_key, alliance) do nothing;


-- =====================================================================
-- 8l. Team members, by id (used by the sections below)
--
--    is_team_member() is is_staff() or is_student() for ANY account, not just the caller's,
--    so a function can check who an entry or shift is for. Internal only.
--    team_member_names() gives team members the display name (or the part of the email before
--    the @) for accounts that appear on a page: scout shifts, the robot log, relayed entries.
-- =====================================================================
create or replace function public.is_team_member(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.member_team(p_user))
      or exists (select 1 from public.staff_members s join auth.users u on u.id = s.user_id
                 where s.user_id = p_user and u.email_confirmed_at is not null
                   and (u.banned_until is null or u.banned_until <= now()));
$$;
revoke all on function public.is_team_member(uuid) from public, anon, authenticated;

create or replace function public.team_member_names(p_ids uuid[])
returns table (user_id uuid, name text)
language sql stable security definer set search_path = '' as $$
  select u.id,
         coalesce(public.account_name(u.raw_user_meta_data), split_part(u.email::text, '@', 1))
  from auth.users u
  where u.id = any(p_ids[1:500])
    and ((select public.is_staff()) or (select public.is_student()));
$$;


-- =====================================================================
-- 8m. Scout shifts (shifts.html)
--
--    A team's managers hand out driver-station seats to its members for a range of
--    qualification matches: "red 2, quals 14-25" (a manager can let every member do it). The
--    whole team can read them, so scouts know where to sit, and the Scout
--    page fills in the team and match for the scout's next assigned match. A seat can't have
--    two scouts at once, and a scout can't be in two seats at once (checked by the trigger).
-- =====================================================================
create table if not exists public.scout_shifts (
  id          bigint generated always as identity primary key,
  event_id    uuid not null references public.events(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  station     text not null check (station in ('red1','red2','red3','blue1','blue2','blue3')),
  first_match int  not null check (first_match between 1 and 999),
  last_match  int  not null check (last_match between 1 and 999),
  note        text check (char_length(note) <= 200),
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  check (last_match >= first_match)
);
create index if not exists scout_shifts_event_idx on public.scout_shifts (event_id, station);
alter table public.scout_shifts enable row level security;

-- Each team hands out its own seats (section 3b); rows from before teams are the home team's
alter table public.scout_shifts add column if not exists owner_team int;
update public.scout_shifts set owner_team = public.home_team() where owner_team is null;
alter table public.scout_shifts alter column owner_team set default public.my_team();
alter table public.scout_shifts alter column owner_team set not null;

-- Security definer so it can call member_team(), which the API can't
create or replace function public.scout_shift_overlap() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (
    select 1 from public.scout_shifts s
    where s.event_id = new.event_id and s.owner_team = new.owner_team and s.id is distinct from new.id
      and s.first_match <= new.last_match and new.first_match <= s.last_match
      and (s.station = new.station or s.user_id = new.user_id)
  ) then
    raise exception 'That overlaps another shift: a seat holds one scout, and a scout sits in one seat, at a time.';
  end if;
  if not exists (select 1 from public.member_team(new.user_id) m where m.team_number = new.owner_team) then
    raise exception 'Shifts can only go to members of your team.';
  end if;
  return new;
end $$;
drop trigger if exists scout_shift_overlap on public.scout_shifts;
create trigger scout_shift_overlap before insert or update on public.scout_shifts
  for each row execute function public.scout_shift_overlap();

drop policy if exists "team reads scout shifts"    on public.scout_shifts;
drop policy if exists "staff manages scout shifts" on public.scout_shifts;
drop policy if exists "team manages scout shifts" on public.scout_shifts;
create policy "team reads scout shifts" on public.scout_shifts for select to authenticated
  using (owner_team = (select public.my_team()));
create policy "team manages scout shifts" on public.scout_shifts for all to authenticated
  using (owner_team = (select public.my_team()) and (select public.team_can('scout_shifts')))
  with check (owner_team = (select public.my_team()) and (select public.team_can('scout_shifts')));


-- =====================================================================
-- 8n. Pick list (picklist.html)
--
--    The ranked list a team builds before alliance selection: order, a tier, and a note per
--    team. Playoff Selection highlights the best-ranked team still available. Each team has its
--    own; its managers write (or every member, if a manager allows it) and the team reads.
--    Rank isn't unique, so a reorder can be saved in one upsert.
-- =====================================================================
create table if not exists public.pick_list (
  event_id    uuid not null references public.events(id) on delete cascade,
  team_number int  not null check (team_number between 1 and 99999),
  rank        int  not null check (rank between 1 and 999),
  tier        text not null default 'maybe' check (tier in ('top','good','maybe','dnp')),
  note        text check (char_length(note) <= 300),
  updated_by  uuid default auth.uid() references auth.users(id) on delete set null,
  updated_at  timestamptz not null default now(),
  primary key (event_id, team_number)
);
alter table public.pick_list enable row level security;

-- Each team's own list (section 3b). Same key change as match_strategies (step 2, section 16b).
alter table public.pick_list add column if not exists owner_team int;
update public.pick_list set owner_team = public.home_team() where owner_team is null;
alter table public.pick_list alter column owner_team set default public.my_team();
alter table public.pick_list alter column owner_team set not null;
do $$
begin
  if not exists (select 1 from pg_index i where i.indrelid = 'public.pick_list'::regclass and i.indisunique
                 and pg_get_indexdef(i.indexrelid) like '%(owner_team, event_id, team_number)%') then
    create unique index pick_list_team_key on public.pick_list (owner_team, event_id, team_number);
  end if;
end $$;

drop policy if exists "team reads pick list"    on public.pick_list;
drop policy if exists "staff manages pick list" on public.pick_list;
drop policy if exists "team manages pick list"  on public.pick_list;
create policy "team reads pick list" on public.pick_list for select to authenticated
  using (owner_team = (select public.my_team()));
create policy "team manages pick list" on public.pick_list for all to authenticated
  using (owner_team = (select public.my_team()) and (select public.team_can('pick_list')))
  with check (owner_team = (select public.my_team()) and (select public.team_can('pick_list')));


-- =====================================================================
-- 8o. Match predictions (matches.html writes them, ratings.html reports on them)
--
--    The win chance Our Matches shows for an upcoming match is saved here through
--    log_prediction(), and replaced each time it's worked out again, until the match has a
--    score. After that it stays as it was, so prediction_calibration() can compare what was
--    predicted with what happened. Nobody writes the table directly.
-- =====================================================================
create table if not exists public.match_predictions (
  event_id        uuid not null references public.events(id) on delete cascade,
  match_key       text not null check (match_key ~ '^(qm[0-9]{1,3}|sf[0-9]{1,2}m[0-9]{1,2}|f1m[0-9]{1,2})$'),
  red_teams       int[] not null check (cardinality(red_teams) = 3),
  blue_teams      int[] not null check (cardinality(blue_teams) = 3),
  red_chance      numeric not null check (red_chance between 0 and 1),
  scouted_chance  numeric check (scouted_chance between 0 and 1),
  official_chance numeric check (official_chance between 0 and 1),
  predicted_at    timestamptz not null default now(),
  primary key (event_id, match_key)
);
alter table public.match_predictions enable row level security;
drop policy if exists "team reads predictions" on public.match_predictions;
create policy "team reads predictions" on public.match_predictions for select to authenticated
  using ((select public.is_staff()) or (select public.is_student()));

-- Saves the latest prediction for a match that hasn't been played. Returns 'saved' or 'played'.
create or replace function public.log_prediction(p_event uuid, p_match text, p_red int[], p_blue int[],
  p_chance numeric, p_scouted numeric, p_official numeric)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_staff() or public.is_student()) then raise exception 'Team members only.'; end if;
  if exists (
    select 1 from public.official_matches m
    where m.event_id = p_event and m.match_key = p_match
      and m.red_score is not null and m.blue_score is not null and (m.red_score > 0 or m.blue_score > 0)
  ) then
    return 'played';
  end if;
  insert into public.match_predictions as p
    (event_id, match_key, red_teams, blue_teams, red_chance, scouted_chance, official_chance, predicted_at)
  values (p_event, p_match, p_red, p_blue, p_chance, p_scouted, p_official, now())
  on conflict (event_id, match_key) do update set
    red_teams = excluded.red_teams, blue_teams = excluded.blue_teams, red_chance = excluded.red_chance,
    scouted_chance = excluded.scouted_chance, official_chance = excluded.official_chance, predicted_at = now()
  where p.red_chance is distinct from excluded.red_chance
     or p.red_teams is distinct from excluded.red_teams or p.blue_teams is distinct from excluded.blue_teams;
  return 'saved';
end $$;

-- How good the saved predictions were, over every played match with one: the Brier score
-- (0 is perfect, 0.25 is a coin flip), how often the favorite won, and the predictions in
-- 10-point buckets with how often red really won in each. A tie counts as half a win.
-- Only predictions whose line-up matches the one that played are counted.
create or replace function public.prediction_calibration() returns jsonb
language sql stable security definer set search_path = '' as $$
  with played as (
    select p.red_chance::float8 as pred,
           case when c.red_score > c.blue_score then 1.0 when c.red_score < c.blue_score then 0.0 else 0.5 end as outcome
    from public.match_predictions p
    join public.official_matches_combined c on c.event_id = p.event_id and c.match_key = p.match_key
    where c.red_score is not null and c.blue_score is not null and (c.red_score > 0 or c.blue_score > 0)
      and (select array_agg(x order by x) from unnest(p.red_teams) x) = (select array_agg(x order by x) from unnest(c.red_teams) x)
      and (select array_agg(x order by x) from unnest(p.blue_teams) x) = (select array_agg(x order by x) from unnest(c.blue_teams) x)
  ), buckets as (
    select least(floor(pred * 10), 9)::int as b, count(*) as n, avg(pred) as avg_pred, avg(outcome) as red_won
    from played group by 1
  )
  select case when not ((select public.is_staff()) or (select public.is_student())) then null else
    jsonb_build_object(
      'matches', (select count(*) from played),
      'brier', (select round(avg((pred - outcome) ^ 2)::numeric, 4) from played),
      'favorite_won', (select round(avg(case when pred = 0.5 or outcome = 0.5 then null
                                             when (pred > 0.5) = (outcome = 1) then 1.0 else 0.0 end)::numeric, 4) from played),
      'buckets', coalesce((select jsonb_agg(jsonb_build_object('from', b * 10, 'to', b * 10 + 10, 'matches', n,
                             'predicted', round(avg_pred::numeric, 3), 'red_won', round(red_won::numeric, 3)) order by b)
                           from buckets), '[]'::jsonb))
  end;
$$;


-- =====================================================================
-- 8p. Robot log (pitcrew.html)
--
--    A team's own robot at an event: the pre-match checklist ticked off for each match, battery
--    use (which battery, its voltage, which match), repairs, and notes. The checklist items and
--    low-battery voltage are the team's settings (teams.settings.pit, section 3b). event_id is
--    blank for shop work.
-- =====================================================================
create table if not exists public.robot_log (
  id          bigint generated always as identity primary key,
  event_id    uuid references public.events(id) on delete set null,
  match_key   text check (match_key ~ '^(qm[0-9]{1,3}|sf[0-9]{1,2}m[0-9]{1,2}|f1m[0-9]{1,2})$'),
  kind        text not null check (kind in ('checklist','battery','repair','note')),
  battery     text check (char_length(battery) <= 20),
  voltage     numeric check (voltage between 0 and 20),
  details     text check (char_length(details) <= 1000),
  checks      jsonb check (checks is null or (jsonb_typeof(checks) = 'object' and octet_length(checks::text) <= 4000)),
  created_by  uuid default auth.uid() references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
alter table public.robot_log enable row level security;

drop policy if exists "team reads robot log"    on public.robot_log;
drop policy if exists "team adds robot log"     on public.robot_log;
drop policy if exists "team edits own robot log" on public.robot_log;
drop policy if exists "team deletes robot log"  on public.robot_log;
-- Each team's own robot (section 3b); rows from before teams are the home team's. Anyone the
-- team lets use Pit Crew adds rows and changes their own; the team's managers can change any.
alter table public.robot_log add column if not exists owner_team int;
update public.robot_log set owner_team = public.home_team() where owner_team is null;
alter table public.robot_log alter column owner_team set default public.my_team();
alter table public.robot_log alter column owner_team set not null;
drop index if exists public.robot_log_event_idx;   -- replaced by the per-team index
create index if not exists robot_log_team_event_idx on public.robot_log (owner_team, event_id, created_at desc);

create policy "team reads robot log" on public.robot_log for select to authenticated
  using (owner_team = (select public.my_team()));
create policy "team adds robot log" on public.robot_log for insert to authenticated
  with check (owner_team = (select public.my_team()) and (select public.team_can('pit_crew')) and created_by = auth.uid());
create policy "team edits own robot log" on public.robot_log for update to authenticated
  using (owner_team = (select public.my_team())
         and ((select public.is_team_manager()) or ((select public.team_can('pit_crew')) and created_by = auth.uid())))
  with check (owner_team = (select public.my_team()));
create policy "team deletes robot log" on public.robot_log for delete to authenticated
  using (owner_team = (select public.my_team())
         and ((select public.is_team_manager()) or ((select public.team_can('pit_crew')) and created_by = auth.uid())));


-- =====================================================================
-- 8q. Match alerts (push notifications)
--
--    A team member can turn on "Tell me when we're about to play" on My Account. The
--    browser's push subscription is saved here through push_subscribe(). While auto-sync is
--    on for an event, a pg_cron job (section 15) calls run_match_alerts(), which asks the
--    match-alerts Edge Function (supabase/functions/match-alerts) to send a notification
--    shortly before a subscribed team needs to queue: from FRC Nexus queuing status where the
--    event uses it, otherwise when its next match is 3 or fewer matches away. match_alerts_sent
--    stops the same alert going out twice. Nothing here is readable through the API except a
--    person's own subscriptions.
-- =====================================================================
create table if not exists public.push_subscriptions (
  endpoint    text primary key check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  user_id     uuid not null references auth.users(id) on delete cascade,
  p256dh      text not null check (char_length(p256dh) <= 200),
  auth_key    text not null check (char_length(auth_key) <= 100),
  team_number int  not null default 1307 check (team_number between 1 and 99999),
  created_at  timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists "people read own push subscriptions" on public.push_subscriptions;
create policy "people read own push subscriptions" on public.push_subscriptions for select to authenticated
  using (user_id = auth.uid());

create table if not exists public.match_alerts_sent (
  event_id    uuid not null references public.events(id) on delete cascade,
  match_key   text not null,
  team_number int  not null,
  sent_at     timestamptz not null default now(),
  primary key (event_id, match_key, team_number)
);
alter table public.match_alerts_sent enable row level security;

-- Save this browser's subscription for the signed-in team member. The endpoint is unique to the
-- browser, so signing in as someone else on it moves the subscription to them.
create or replace function public.push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_team int)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not (public.is_staff() or public.is_student()) then raise exception 'Team members only.'; end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth_key, team_number)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth, coalesce(p_team, 1307))
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh,
    auth_key = excluded.auth_key, team_number = excluded.team_number, created_at = now();
end $$;

create or replace function public.push_unsubscribe(p_endpoint text) returns void
language sql security definer set search_path = '' as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- Called by pg_cron only (section 15). Cheap when nobody is subscribed or auto-sync is off.
create or replace function public.run_match_alerts() returns void
language plpgsql set search_path = '' as $$
declare
  v_event  uuid;
  v_secret text;
begin
  select id into v_event from public.events where auto_sync;
  if v_event is null or not exists (select 1 from public.push_subscriptions) then return; end if;
  select btrim(decrypted_secret, E' \t\r\n') into v_secret from vault.decrypted_secrets where name = 'sync_secret';
  if v_secret is null or v_secret = '' then return; end if;
  perform net.http_post(
    url     := 'https://nyanwljgsazwuzmnlrcz.supabase.co/functions/v1/match-alerts',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', v_secret),
    body    := jsonb_build_object('event_id', v_event),
    timeout_milliseconds := 30000);
end $$;
revoke all on function public.run_match_alerts() from public, anon, authenticated;


-- =====================================================================
-- 8r. Vision pre-fill and relayed entries (scout.html)
--
--    prefilled lists the fields of an entry the Scout page filled in from vision data, so
--    the vision-vs-scouts comparison on Match Flags can leave those out (they'd agree by
--    construction). relayed_by is set when the entry reached the server from another team
--    member's device, scanned off the scout's screen as a QR code because the scout's device
--    had no connection. The entry still belongs to the scout who made it.
-- =====================================================================
alter table public.scouting_entries add column if not exists prefilled text[]
  check (prefilled is null or cardinality(prefilled) <= 50);
alter table public.scouting_entries add column if not exists relayed_by uuid
  references auth.users(id) on delete set null;

-- Save an entry scanned from another team member's device. It keeps that scout as scouted_by
-- (who must be a team member) and its own id, so scanning it twice, or the scout's device
-- sending it later as well, can't save it twice. Returns 'saved' or 'already saved'.
create or replace function public.relay_scouting_entry(p_entry jsonb) returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_by uuid;
begin
  if not (public.is_staff() or public.is_student()) then raise exception 'Team members only.'; end if;
  v_id := (p_entry ->> 'id')::uuid;
  v_by := (p_entry ->> 'scouted_by')::uuid;
  if v_id is null or v_by is null then raise exception 'The entry is missing its id or its scout.'; end if;
  if not public.is_team_member(v_by) then raise exception 'The scout on this entry is not a team member.'; end if;
  if exists (select 1 from public.scouting_entries where id = v_id) then return 'already saved'; end if;
  insert into public.scouting_entries (id, event_id, team_number, match_number, data, scouted_by, prefilled, relayed_by)
  values (v_id, (p_entry ->> 'event_id')::uuid, (p_entry ->> 'team_number')::int,
          nullif(p_entry ->> 'match_number', '')::int, coalesce(p_entry -> 'data', '{}'::jsonb), v_by,
          case when jsonb_typeof(p_entry -> 'prefilled') = 'array'
               then array(select jsonb_array_elements_text(p_entry -> 'prefilled')) end,
          auth.uid());
  return 'saved';
end $$;


-- =====================================================================
-- 8s. Public season results (results.html)
--
--    The one piece of official data anyone can read without signing in: team 1307's own
--    played matches, for the public Season Results page. Official results are public on
--    FRC Events and TBA already. Security definer so it can use the team indexes without
--    opening the official tables to everyone.
-- =====================================================================
create or replace function public.public_team_results()
returns table (event_name text, event_date date, event_tier text, tba_event_key text,
               match_key text, comp_level text, set_number int, match_number int, alliance text,
               partners int[], opponents int[], our_score int, their_score int, played_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select e.name::text, e.event_date, e.event_tier, e.tba_event_key,
         c.match_key, c.comp_level, c.set_number, c.match_number,
         case when 1307 = any(c.red_teams) then 'red' else 'blue' end,
         array_remove(case when 1307 = any(c.red_teams) then c.red_teams else c.blue_teams end, 1307),
         case when 1307 = any(c.red_teams) then c.blue_teams else c.red_teams end,
         case when 1307 = any(c.red_teams) then c.red_score else c.blue_score end,
         case when 1307 = any(c.red_teams) then c.blue_score else c.red_score end,
         c.played_at
  from public.official_matches_combined c
  join public.events e on e.id = c.event_id
  where (c.red_teams && array[1307] or c.blue_teams && array[1307])
    and c.red_score is not null and c.blue_score is not null and (c.red_score > 0 or c.blue_score > 0)
  order by e.event_date, e.name, c.played_at nulls last, c.match_key;
$$;


-- =====================================================================
-- 9. Team rating (the S-F grade). Plain-language version for users: ratings.html.
--    Keep that page in step with any change to the math below.
--
--    TWO SEPARATE RANKINGS, never blended into one number:
--      team_ratings() / team_points_summary()  — scouting rating, built
--        only from what students/staff scouted by hand (match entries +
--        the pit form). Has no idea official results even exist.
--      team_official_ratings() / team_official_summary() — official
--        rating, built only from FRC Events / TBA synced match results.
--        Has no idea scouting entries even exist.
--    Earlier versions blended a 12%-weighted "official" component into
--    team_ratings(), which is what caused the confusing "0 matches / Not
--    rated" badge next to a fully-played official record on the Team
--    Database page (the official component could only count once a team
--    ALSO had 3+ scouted matches, so a team with great official results
--    but no scouting coverage looked unrated even though real results
--    existed). Splitting them removes that overlap: a team now gets
--    independently rated on whichever kind of data it actually has.
--
--    team_ratings(): only 2026 REBUILT entries count (older seasons are
--    ignored). A team's score is a 0-100 weighted blend of seven scouted
--    components. Components a team has no data for are skipped and the
--    remaining weights are rescaled, so a team is never punished for
--    missing pit data.
--
--      32  FUEL scoring    avg FUEL points per scoring match, ranked against other teams
--      16  TOWER climb     avg TOWER points (auto + teleop), ranked
--       9  Autonomous      avg auto points (80%, ranked) + left-zone rate (20%)
--      11  Efficiency      FUEL per volley (ranked) + scouted accuracy, averaged
--      16  Reliability     1 - (disabled rate + 0.6 x broke-down rate + 0.4 x stuck rate)
--       5  Discipline      1 - foul/card rate
--      11  Robot capability  pit form: climb level, trench fit, intake, shooter, drivetrain,
--                            FUEL capacity, shooting range, vision (see pit_capability())
--
--    When several scouts enter the same team, event and match number, their entries are
--    averaged into one match first, so a double-scouted match counts once. Test teams are
--    ranked in their own group, so they can't shift a real team's rank at any step.
--    Matches where the scout marked the role as Defense or Feeder are left out of
--    the FUEL-scoring average, so a good defender isn't graded as a bad scorer.
--    Letter grade = where the score ranks among rated teams:
--      S top 10%, A next 15%, B next 25%, C next 25%, D next 15%, F bottom 10%.
--    Not graded (informational only): main FUEL source, volley count, notes, robot photo.
--    To change the weights, edit the numbers in the (w, c) list near the end of team_ratings().
--
--    team_official_ratings(): a single-metric ranking from FRC Events / TBA
--    results. The score is the team's OPR: about how many points it adds to
--    its alliance per match, worked out from qualification matches at each
--    event (official_opr_fill()), then averaged across events weighted by
--    matches played and by event tier (event_tier_weight()): 2.0x at the
--    FIRST Championship, 1.5x at a District Championship, 1.0x at a regular
--    qualifier, 0.75x off-season. Chosen over the earlier 60% alliance score +
--    40% win rate blend after testing both on the full 2026 season: OPR
--    separates a team from its partners, so a weak robot carried by strong
--    partners (often in playoffs) no longer rates high. Record and average
--    alliance score are still returned as plain stats.
-- =====================================================================
create or replace function public.jnum(d jsonb, k text) returns numeric
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(d -> k) = 'number' then (d ->> k)::numeric end
$$;
create or replace function public.jbool(d jsonb, k text) returns boolean
language sql immutable set search_path = '' as $$
  select case when jsonb_typeof(d -> k) = 'boolean' then (d ->> k)::boolean end
$$;

-- Table 6-4 of the 2026 manual: 1 point per FUEL in an active HUB (auto and teleop);
-- TOWER: L1 = 15 in AUTO and 10 in TELEOP, L2 = 20 in TELEOP, L3 = 30 in TELEOP.
create or replace function public.rebuilt_fuel_points(d jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select coalesce(public.jnum(d, 'auto_fuel_hub'), 0) + coalesce(public.jnum(d, 'teleop_fuel_hub'), 0)
$$;
create or replace function public.rebuilt_tower_points(d jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select (case d ->> 'auto_tower' when 'L1' then 15 else 0 end)
       + (case d ->> 'teleop_tower' when 'L1' then 10 when 'L2' then 20 when 'L3' then 30 else 0 end)
$$;
create or replace function public.rebuilt_auto_points(d jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select coalesce(public.jnum(d, 'auto_fuel_hub'), 0)
       + (case d ->> 'auto_tower' when 'L1' then 15 else 0 end)
$$;
create or replace function public.rebuilt_points(d jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select public.rebuilt_fuel_points(d) + public.rebuilt_tower_points(d)
$$;

-- Pit form -> 0..1. Each answered question scores 0..1 and the answers are averaged.
-- (The robot photo is informational only and never enters this score.)
create or replace function public.pit_capability(d jsonb) returns numeric
language sql immutable set search_path = '' as $$
  select avg(s) from (values
    (case d ->> 'tower_max_level' when 'None' then 0 when 'L1' then .33 when 'L2' then .67 when 'L3' then 1 end),
    (case public.jbool(d, 'trench_capable') when true then 1 when false then 0 end),
    (case d ->> 'intake_type' when 'None' then 0 when 'Front' then .7 when 'Side' then .7 when 'Front and side' then 1 end),
    (case d ->> 'shooter_type' when 'Fixed flywheel' then .4 when 'Adjustable hood' then .7 when 'Turret' then 1 when 'Other' then .5 end),
    (case d ->> 'drivetrain' when 'Swerve' then 1 when 'West Coast' then .8 when 'Tank' then .65 when 'Mecanum' then .5 when 'Other' then .5 end),
    (case when public.jnum(d, 'fuel_capacity') is not null then least(public.jnum(d, 'fuel_capacity') / 30, 1) end),
    (case when public.jnum(d, 'shooter_max_range_ft') is not null then least(public.jnum(d, 'shooter_max_range_ft') / 20, 1) end),
    (case public.jbool(d, 'uses_vision') when true then 1 when false then 0 end)
  ) v(s)
$$;

create or replace function public.team_ratings()
returns table (team_number int, matches int, disabled_matches int, avg_points numeric,
               score numeric, grade text, percentile numeric, components jsonb)
language sql stable security definer set search_path = '' as $$
  with entries as (
    select s.id, s.event_id, s.match_number, s.team_number, s.data as d,
           public.rebuilt_fuel_points(s.data)  as fuel_pts,
           public.rebuilt_tower_points(s.data) as tower_pts,
           public.rebuilt_auto_points(s.data)  as auto_pts,
           coalesce(s.data ->> 'teleop_role', 'Scorer') not in ('Defense', 'Feeder') as scoring_match
    from public.scouting_entries s
    where ((select public.is_staff()) or (select public.is_student()))
      and s.data ?| array['stuck_on_field','foul_or_card','auto_fuel_hub','teleop_fuel_hub','auto_tower','teleop_tower']
  ),
  -- One row per match: when several scouts entered the same match, their entries are averaged
  -- so it counts once. An entry with no match number can't be paired, so it stands alone.
  per_match as (
    select e.team_number,
      avg(e.fuel_pts + e.tower_pts) as points,
      avg(e.fuel_pts) filter (where e.scoring_match) as fuel_pts,
      avg(e.tower_pts) as tower_pts,
      avg(e.auto_pts) as auto_pts,
      avg(case public.jbool(e.d, 'auto_mobility') when true then 1 when false then 0 end) as mobility,
      avg(public.jnum(e.d, 'shooter_accuracy')) as accuracy,
      avg(coalesce(public.jnum(e.d, 'teleop_fuel_per_volley'),
                   public.jnum(e.d, 'teleop_fuel_hub') / nullif(public.jnum(e.d, 'teleop_volleys'), 0))) as fpv,
      avg(case when coalesce(public.jbool(e.d, 'robot_disabled'), false) then 1 else 0 end)::numeric as dis,
      avg(case when coalesce(public.jbool(e.d, 'broke_down'), false) then 1 else 0 end)::numeric as broke,
      avg(case when coalesce(public.jbool(e.d, 'stuck_on_field'), false) then 1 else 0 end)::numeric as stuck,
      avg(case when coalesce(public.jbool(e.d, 'foul_or_card'), false) then 1 else 0 end)::numeric as foul
    from entries e
    group by e.team_number, e.event_id, coalesce(e.match_number::text, e.id::text)
  ),
  agg as (
    select m.team_number,
      count(*)::int as matches,
      count(*) filter (where m.dis > 0)::int as disabled_matches,
      avg(m.points) as avg_points,
      avg(m.fuel_pts) as fuel_avg,
      avg(m.tower_pts) as tower_avg,
      avg(m.auto_pts) as auto_avg,
      avg(m.mobility) as mobility_rate,
      avg(m.accuracy) as accuracy_avg,
      avg(m.fpv) as fpv_avg,
      avg(m.dis) as dis_rate,
      avg(m.broke) as broke_rate,
      avg(m.stuck) as stuck_rate,
      avg(m.foul) as foul_rate,
      exists (select 1 from public.test_teams tt where tt.team_number = m.team_number) as is_test
    from per_match m
    group by m.team_number
  ),
  pit as (
    select distinct on (p.team_number) p.team_number, public.pit_capability(p.data) as cap
    from public.pit_entries p
    where (select public.is_staff()) or (select public.is_student())
    order by p.team_number, p.updated_at desc
  ),
  base as (
    select a.*, pit.cap,
      case when a.fuel_avg  is not null then (cume_dist() over (partition by a.is_test, (a.fuel_avg  is not null) order by a.fuel_avg))::numeric end as p_fuel,
      case when a.tower_avg is not null then (cume_dist() over (partition by a.is_test, (a.tower_avg is not null) order by a.tower_avg))::numeric end as p_tower,
      case when a.auto_avg  is not null then (cume_dist() over (partition by a.is_test, (a.auto_avg  is not null) order by a.auto_avg))::numeric end as p_auto,
      case when a.fpv_avg   is not null then (cume_dist() over (partition by a.is_test, (a.fpv_avg   is not null) order by a.fpv_avg))::numeric end as p_fpv
    from agg a
    left join pit on pit.team_number = a.team_number
  ),
  comp as (
    select b.*,
      b.p_fuel  as c_fuel,
      b.p_tower as c_climb,
      coalesce(0.8 * b.p_auto + 0.2 * b.mobility_rate, b.p_auto) as c_auto,
      (select avg(x) from (values (b.p_fpv), ((b.accuracy_avg - 1) / 4)) v(x)) as c_eff,
      greatest(0, 1 - (b.dis_rate + 0.6 * b.broke_rate + 0.4 * b.stuck_rate)) as c_rel,
      greatest(0, 1 - b.foul_rate) as c_disc,
      b.cap as c_pit
    from base b
  ),
  scored as (
    select c.*,
      100 * (select sum(w * x) / sum(w)
               from (values (32, c.c_fuel), (16, c.c_climb), (9, c.c_auto), (11, c.c_eff),
                            (16, c.c_rel), (5, c.c_disc), (11, c.c_pit)) v(w, x)
              where x is not null) as raw_score
    from comp c
  ),
  ranked as (
    select s.*, (cume_dist() over (partition by s.is_test order by s.raw_score))::numeric as pct
    from scored s
  )
  select r.team_number, r.matches, r.disabled_matches,
         round(r.avg_points, 2),
         round(r.raw_score, 1),
         case when r.pct >= .90 then 'S' when r.pct >= .75 then 'A' when r.pct >= .50 then 'B'
              when r.pct >= .25 then 'C' when r.pct >= .10 then 'D' else 'F' end,
         round(r.pct, 3),
         jsonb_strip_nulls(jsonb_build_object(
           'fuel',        round(100 * r.c_fuel, 1),
           'climb',       round(100 * r.c_climb, 1),
           'auto',        round(100 * r.c_auto, 1),
           'efficiency',  round(100 * r.c_eff, 1),
           'reliability', round(100 * r.c_rel, 1),
           'discipline',  round(100 * r.c_disc, 1),
           'pit',         round(100 * r.c_pit, 1)))
  from ranked r;
$$;

-- Older callers (and the Team Database before the rating update) used this shape
create or replace function public.team_points_summary()
returns table (team_number int, matches int, disabled_matches int, avg_points numeric)
language sql stable security definer set search_path = '' as $$
  select t.team_number, t.matches, t.disabled_matches, t.avg_points from public.team_ratings() t;
$$;

-- How much an event's results count toward a team's official rating. A win or a high score at a
-- District Championship or the FIRST Championship says more about a team than the same result at
-- a regular qualifier does — the field is tougher — so it should move the rating more. An
-- off-season result counts a little less, since off-seasons vary a lot in how competitive the
-- field is and FIRST doesn't operate them. To retune the system, change the numbers here; every
-- other query that cares about event strength goes through this one function.
create or replace function public.event_tier_weight(tier text) returns numeric
language sql immutable set search_path = '' as $$
  select case tier
    when 'championship'            then 2.0   -- FIRST Championship (Worlds)
    when 'district_championship'   then 1.5   -- a district's own championship event
    when 'offseason'                then 0.75  -- off-season / scrimmage events
    else 1.0                                    -- 'qualifier': a normal regular-season event
  end
$$;

-- Per-event OPR, one row per team per event, rebuilt by official_opr_fill() during
-- refresh_official_cache(). Read by official_ratings_compute() and get_shared_scouting().
-- Row-level security on with no policies: only those functions read it.
create table if not exists public.official_opr_cache (
  event_id    uuid not null references public.events(id) on delete cascade,
  team_number int  not null,
  opr         double precision not null,   -- points this team adds to its alliance per match
  matches     int  not null,               -- qualification matches it played at the event
  primary key (event_id, team_number)
);
alter table public.official_opr_cache enable row level security;
revoke all on public.official_opr_cache from anon, authenticated;

-- OPR for every event at once, from played qualification matches. The same model as
-- js/opr.js: each alliance's score is the sum of its three robots' numbers, solved by least
-- squares with a pull of 1 match's worth toward the event's average robot (so a team with few
-- matches stays near average instead of swinging wildly). Solved by conjugate gradient, which
-- reaches the exact answer in at most one step per team at the event; every event is solved
-- side by side, so each step is a few set-based statements over all of them.
-- p_events limits it to those events (only their cache rows are replaced); null redoes every
-- event. The cron refresh passes just the events a sync changed, so a competition-day sync
-- solves one event instead of the whole season.
drop function if exists public.official_opr_fill();
create or replace function public.official_opr_fill(p_events uuid[] default null) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_ridge constant double precision := 1;
  v_tol   constant double precision := 1e-6;   -- squared residual, in points^2
begin
  drop table if exists pg_temp.opr_all, pg_temp.opr_app, pg_temp.opr_vec, pg_temp.opr_ev;

  -- One row per alliance in a played qualification match
  create temp table opr_all on commit drop as
  select c.event_id, c.match_key || ':r' as aid, c.red_score::double precision as score, c.red_teams as teams
    from public.official_matches_combined c
   where c.comp_level = 'qm' and c.red_score is not null and c.blue_score is not null
     and (p_events is null or c.event_id = any(p_events))
  union all
  select c.event_id, c.match_key || ':b', c.blue_score::double precision, c.blue_teams
    from public.official_matches_combined c
   where c.comp_level = 'qm' and c.red_score is not null and c.blue_score is not null
     and (p_events is null or c.event_id = any(p_events));

  -- One row per robot on each alliance
  create temp table opr_app on commit drop as
  select distinct a.event_id, a.aid, t.team as team_number
    from opr_all a cross join lateral unnest(a.teams) as t(team)
   where t.team is not null and t.team > 0;

  -- Per event: the average robot (alliance average / 3) and the solver's running numbers
  create temp table opr_ev on commit drop as
  select event_id, avg(score) / 3 as mu, 0::double precision as rs,
         0::double precision as rs_new, 0::double precision as pap
    from opr_all group by event_id;

  -- Per team per event: matches, right-hand side b, answer x, residual r, direction p, A*p
  create temp table opr_vec on commit drop as
  select ap.event_id, ap.team_number, count(*)::int as n,
         sum(a.score) + v_ridge * e.mu as b,
         e.mu as x, 0::double precision as r, e.mu as p, 0::double precision as ap
    from opr_app ap
    join opr_all a on a.event_id = ap.event_id and a.aid = ap.aid
    join opr_ev e on e.event_id = ap.event_id
   group by ap.event_id, ap.team_number, e.mu;
  create unique index on opr_vec (event_id, team_number);
  create index on opr_app (event_id, aid);

  -- A*p, where A = ridge*I + (robot-alliance matrix)^T (robot-alliance matrix):
  -- each robot's A*p is ridge*p plus the sum of p over every alliance it was on.
  -- Run once with p = x (the starting guess) to get the first residual.
  for i in 0..400 loop
    with alliance_sum as (
      select ap.event_id, ap.aid, sum(v.p) as sp
        from opr_app ap join opr_vec v on v.event_id = ap.event_id and v.team_number = ap.team_number
       group by ap.event_id, ap.aid
    ), robot_sum as (
      select ap.event_id, ap.team_number, sum(s.sp) as m
        from opr_app ap join alliance_sum s on s.event_id = ap.event_id and s.aid = ap.aid
       group by ap.event_id, ap.team_number
    )
    update opr_vec v set ap = v_ridge * v.p + rsum.m
      from robot_sum rsum where rsum.event_id = v.event_id and rsum.team_number = v.team_number;

    if i = 0 then
      -- Starting residual r = b - A*x, first direction p = r
      update opr_vec set r = b - ap, p = b - ap;
      update opr_ev e set rs = s.v
        from (select event_id, sum(r * r) as v from opr_vec group by event_id) s
       where s.event_id = e.event_id;
    else
      update opr_ev e set pap = s.v
        from (select event_id, sum(p * ap) as v from opr_vec group by event_id) s
       where s.event_id = e.event_id;
      -- Step along p; events already solved take a step of 0
      update opr_vec v set x = v.x + st.alpha * v.p, r = v.r - st.alpha * v.ap
        from (select event_id, case when rs > v_tol and pap > 0 then rs / pap else 0 end as alpha
                from opr_ev) st
       where st.event_id = v.event_id;
      update opr_ev e set rs_new = s.v
        from (select event_id, sum(r * r) as v from opr_vec group by event_id) s
       where s.event_id = e.event_id;
      update opr_vec v set p = v.r + (case when e.rs > v_tol then e.rs_new / e.rs else 0 end) * v.p
        from opr_ev e where e.event_id = v.event_id;
      update opr_ev set rs = rs_new;
    end if;
    exit when not exists (select 1 from opr_ev where rs > v_tol);
  end loop;

  delete from public.official_opr_cache where p_events is null or event_id = any(p_events);
  insert into public.official_opr_cache (event_id, team_number, opr, matches)
  select event_id, team_number, x, n from opr_vec;
end $$;

-- Official rating, scored purely from synced FRC Events / TBA results (entirely independent of
-- scouting data). score = the team's OPR averaged over its events, each event weighted by
-- qualification matches played x event_tier_weight(). A team needs 3 qualification matches for
-- an OPR-based score; with fewer, score/grade/percentile are null and pages show it as not rated.
-- Record and average alliance score (tier-weighted) are plain stats alongside it.
-- This computes it from the OPR cache; pages read the cached result through
-- team_official_ratings() (the official rating cache, below).
create or replace function public.official_ratings_compute()
returns table (team_number int, matches int, wins int, losses int, ties int,
               avg_alliance_score numeric, score numeric, grade text, percentile numeric)
language sql stable security definer set search_path = '' as $$
  with weighted as (
    select o.team_number, o.alliance_score, o.opponent_score,
           public.event_tier_weight(e.event_tier) as w
    from public.official_team_matches o
    join public.events e on e.id = o.event_id
  ),
  agg as (
    select m.team_number,
      count(*)::int as matches,
      count(*) filter (where m.alliance_score > m.opponent_score)::int as wins,
      count(*) filter (where m.alliance_score < m.opponent_score)::int as losses,
      count(*) filter (where m.alliance_score = m.opponent_score)::int as ties,
      sum(m.alliance_score * m.w) / sum(m.w) as avg_score,
      exists (select 1 from public.test_teams tt where tt.team_number = m.team_number) as is_test
    from weighted m
    group by m.team_number
  ),
  opr as (
    select c.team_number,
           sum(c.opr * public.event_tier_weight(e.event_tier) * c.matches)
             / sum(public.event_tier_weight(e.event_tier) * c.matches) as rating,
           sum(c.matches) as qual_matches
    from public.official_opr_cache c
    join public.events e on e.id = c.event_id
    group by c.team_number
  ),
  scored as (
    select a.*, case when o.qual_matches >= 3 then o.rating end as rating
    from agg a left join opr o on o.team_number = a.team_number
  ),
  pct as (
    -- Test teams and unrated teams are ranked in their own groups
    select s.*, case when s.rating is not null then
             (cume_dist() over (partition by s.is_test, s.rating is null order by s.rating))::numeric
           end as pct
    from scored s
  )
  select p.team_number, p.matches, p.wins, p.losses, p.ties,
         round(p.avg_score, 2), round(p.rating::numeric, 1),
         case when p.pct is null then null
              when p.pct >= .90 then 'S' when p.pct >= .75 then 'A' when p.pct >= .50 then 'B'
              when p.pct >= .25 then 'C' when p.pct >= .10 then 'D' else 'F' end,
         round(p.pct, 3)
  from pct p;
$$;

-- Official rating cache. With a full season synced, working out the official ratings and
-- summary from every match takes several seconds, and pages ask for them on every load. So
-- refresh_official_cache() stores the results in two tables, and team_official_ratings() /
-- team_official_summary() read those instead.
--   - A sync re-sends every match of the event, so official_matches_skip_unchanged drops any
--     row update that changes nothing but updated_at. Without it each 2-minute auto-sync
--     rewrote every row (score breakdowns, indexes) and ran out the database's disk IO budget.
--   - A match row that really changed records its event in official_cache_dirty and bumps
--     official_cache_seq. A change to an event's tier or to test_teams only bumps the sequence
--     (neither changes OPR). The sequence means the writer never waits on a lock.
--   - A pg_cron job (section 15) runs refresh_official_cache() every 3 minutes; it does nothing
--     unless the sequence moved, and re-solves OPR only for the dirty events. So ratings lag a
--     sync by up to 3 minutes.
--   - This file runs a full refresh at the end of section 15, so the cache is never empty.
-- The cache tables have row-level security on and no policies: only these functions read them.
create table if not exists public.official_ratings_cache (
  team_number int primary key, matches int, wins int, losses int, ties int,
  avg_alliance_score numeric, score numeric, grade text, percentile numeric
);
create table if not exists public.official_summary_cache (
  team_number int primary key, matches int, wins int, avg_alliance_score numeric
);
create table if not exists public.official_cache_state (
  id boolean primary key default true check (id),   -- always one row
  refreshed_stamp bigint not null,
  refreshed_at timestamptz not null
);
alter table public.official_ratings_cache enable row level security;
alter table public.official_summary_cache enable row level security;
alter table public.official_cache_state   enable row level security;
revoke all on public.official_ratings_cache, public.official_summary_cache, public.official_cache_state
  from anon, authenticated;
create sequence if not exists public.official_cache_seq;
revoke all on sequence public.official_cache_seq from anon, authenticated;

-- Events whose matches changed since the last refresh. No key, so writers never wait on each
-- other or on the refresh; a null event_id means every event (after a truncate).
create table if not exists public.official_cache_dirty (event_id uuid);
alter table public.official_cache_dirty enable row level security;
revoke all on public.official_cache_dirty from anon, authenticated;

-- Skips a match update that changes nothing but updated_at (see the notes above)
create or replace function public.official_matches_skip_unchanged() returns trigger
language plpgsql set search_path = '' as $$
begin
  if (to_jsonb(new) - 'updated_at') = (to_jsonb(old) - 'updated_at') then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists official_matches_skip_unchanged on public.official_matches;
create trigger official_matches_skip_unchanged before update on public.official_matches
  for each row execute function public.official_matches_skip_unchanged();

-- Marks the cache out of date. Statement-level, so a sync that writes 100 rows bumps it once.
create or replace function public.official_cache_touch() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform nextval('public.official_cache_seq');
  return null;
end $$;

-- Marks the events of the match rows a statement really changed. Skipped updates aren't in
-- new_rows, so a sync that changed nothing marks nothing.
create or replace function public.official_matches_changed() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if TG_OP = 'DELETE' then
    insert into public.official_cache_dirty (event_id) select distinct event_id from old_rows;
  else
    insert into public.official_cache_dirty (event_id) select distinct event_id from new_rows;
  end if;
  if found then
    perform nextval('public.official_cache_seq');
  end if;
  return null;
end $$;
create or replace function public.official_matches_truncated() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.official_cache_dirty (event_id) values (null);
  perform nextval('public.official_cache_seq');
  return null;
end $$;
drop trigger if exists official_matches_cache_touch on public.official_matches;
drop trigger if exists official_matches_changed_ins on public.official_matches;
drop trigger if exists official_matches_changed_upd on public.official_matches;
drop trigger if exists official_matches_changed_del on public.official_matches;
drop trigger if exists official_matches_truncated on public.official_matches;
-- One trigger per kind of write: Postgres allows transition tables only on single-event triggers
create trigger official_matches_changed_ins after insert on public.official_matches
  referencing new table as new_rows for each statement execute function public.official_matches_changed();
create trigger official_matches_changed_upd after update on public.official_matches
  referencing new table as new_rows for each statement execute function public.official_matches_changed();
create trigger official_matches_changed_del after delete on public.official_matches
  referencing old table as old_rows for each statement execute function public.official_matches_changed();
create trigger official_matches_truncated after truncate on public.official_matches
  for each statement execute function public.official_matches_truncated();
drop trigger if exists events_cache_touch on public.events;
create trigger events_cache_touch after update of event_tier
  on public.events for each statement execute function public.official_cache_touch();
drop trigger if exists test_teams_cache_touch on public.test_teams;
create trigger test_teams_cache_touch after insert or update or delete
  on public.test_teams for each statement execute function public.official_cache_touch();

-- Rebuilds the cache if anything changed since the last refresh (or always, with p_force).
-- Returns whether it refreshed. Only pg_cron and the SQL Editor call it: it isn't granted to
-- any API role, since a full refresh can run longer than the API's statement timeout.
create or replace function public.refresh_official_cache(p_force boolean default false)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_stamp  bigint;
  v_events uuid[];
  v_all    boolean;
begin
  if not pg_try_advisory_xact_lock(hashtext('public.refresh_official_cache')) then
    return false;   -- another refresh is already running
  end if;
  if not p_force and exists (
    select 1 from public.official_cache_state s
    where s.refreshed_stamp >= (select last_value from public.official_cache_seq)
  ) then
    return false;   -- nothing changed
  end if;
  -- Taken before reading, so a write during the refresh leaves the cache marked out of date
  v_stamp := nextval('public.official_cache_seq');
  -- Claim the dirty events; any marked after this wait for the next refresh
  with claimed as (delete from public.official_cache_dirty returning event_id)
  select bool_or(event_id is null), array_agg(distinct event_id) filter (where event_id is not null)
    into v_all, v_events from claimed;
  if p_force or v_all then
    perform public.official_opr_fill();
  elsif v_events is not null then
    perform public.official_opr_fill(v_events);
  end if;
  delete from public.official_ratings_cache;
  insert into public.official_ratings_cache select * from public.official_ratings_compute();
  delete from public.official_summary_cache;
  insert into public.official_summary_cache select * from public.official_summary_compute();
  insert into public.official_cache_state (id, refreshed_stamp, refreshed_at)
    values (true, v_stamp, now())
    on conflict (id) do update set refreshed_stamp = excluded.refreshed_stamp,
                                   refreshed_at    = excluded.refreshed_at;
  return true;
end $$;

-- What pages call. Same columns as before the cache existed.
create or replace function public.team_official_ratings()
returns table (team_number int, matches int, wins int, losses int, ties int,
               avg_alliance_score numeric, score numeric, grade text, percentile numeric)
language sql stable security definer set search_path = '' as $$
  select c.team_number, c.matches, c.wins, c.losses, c.ties,
         c.avg_alliance_score, c.score, c.grade, c.percentile
  from public.official_ratings_cache c
  where (select public.is_staff()) or (select public.is_student());
$$;
create or replace function public.team_official_summary()
returns table (team_number int, matches int, wins int, avg_alliance_score numeric)
language sql stable security definer set search_path = '' as $$
  select c.team_number, c.matches, c.wins, c.avg_alliance_score
  from public.official_summary_cache c
  where (select public.is_staff()) or (select public.is_student());
$$;

-- Per-team counters for the Team Database's data-source breakdown: how many matches came from
-- scouting, how many from official sync, and how many matches have BOTH (so the page can show
-- its numbers don't silently double anything). A match counts as overlapping only when a scouted
-- entry and an official qualification-match result agree on the same event and match number.
create or replace function public.team_data_counts()
returns table (team_number int, scouted_matches int, official_matches int, overlap_matches int)
language sql stable security definer set search_path = '' as $$
  with scouted as (
    select s.team_number, count(distinct (s.event_id, s.match_number))::int as n
    from public.scouting_entries s
    where ((select public.is_staff()) or (select public.is_student())) and s.match_number is not null
    group by s.team_number
  ),
  officials as (
    -- Played official matches per team; the rating cache's count is exactly that
    select c.team_number, c.matches as n
    from public.official_ratings_cache c
    where (select public.is_staff()) or (select public.is_student())
  ),
  overlap as (
    -- Starts from the scouting entries and looks up each one's official match by event and
    -- match number (indexed), instead of expanding every official match first
    select s.team_number, count(distinct (s.event_id, s.match_number))::int as n
    from public.scouting_entries s
    where ((select public.is_staff()) or (select public.is_student())) and s.match_number is not null
      and exists (
        select 1 from public.official_matches_combined o
        where o.event_id = s.event_id and o.comp_level = 'qm' and o.match_number = s.match_number
          and o.red_score is not null and o.blue_score is not null
          and s.team_number = any(o.red_teams || o.blue_teams))
    group by s.team_number
  )
  select coalesce(sc.team_number, off.team_number, ov.team_number),
         coalesce(sc.n, 0), coalesce(off.n, 0), coalesce(ov.n, 0)
  from scouted sc
  full join officials off on off.team_number = sc.team_number
  full join overlap ov on ov.team_number = coalesce(sc.team_number, off.team_number);
$$;

-- The per-team lists above, as one JSON value per list, in a single call. Sent as rows, each list
-- is capped at 1000 per request, so pages paged through them and every page re-ran the function
-- (team_ratings() and team_data_counts() are computed live). p_parts picks the lists:
-- ratings, official_ratings, data_counts, official_summary, pit_teams (team numbers with pit data).
-- Keys inside each list are the column names, as a direct call returns them. Pages fall back to
-- the direct calls if this function is missing.
create or replace function public.team_lists(p_parts text[])
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  r jsonb := '{}'::jsonb;
begin
  if not (public.is_staff() or public.is_student()) then raise exception 'Team members only.'; end if;
  if 'ratings' = any(p_parts) then
    r := r || jsonb_build_object('ratings', (select coalesce(jsonb_agg(to_jsonb(t) order by t.team_number), '[]'::jsonb)
                                               from public.team_ratings() t));
  end if;
  if 'official_ratings' = any(p_parts) then
    r := r || jsonb_build_object('official_ratings', (select coalesce(jsonb_agg(to_jsonb(t) order by t.team_number), '[]'::jsonb)
                                                        from public.team_official_ratings() t));
  end if;
  if 'data_counts' = any(p_parts) then
    r := r || jsonb_build_object('data_counts', (select coalesce(jsonb_agg(to_jsonb(t) order by t.team_number), '[]'::jsonb)
                                                   from public.team_data_counts() t));
  end if;
  if 'official_summary' = any(p_parts) then
    r := r || jsonb_build_object('official_summary', (select coalesce(jsonb_agg(to_jsonb(t) order by t.team_number), '[]'::jsonb)
                                                        from public.team_official_summary() t));
  end if;
  if 'pit_teams' = any(p_parts) then
    r := r || jsonb_build_object('pit_teams', (select coalesce(jsonb_agg(distinct p.team_number), '[]'::jsonb)
                                                 from public.pit_entries p));
  end if;
  return r;
end $$;
revoke all on function public.team_lists(text[]) from public, anon;
grant execute on function public.team_lists(text[]) to authenticated;


-- =====================================================================
-- 9b. Storage: scouting photos
--
--    Backs the 'image' field type (section 4). Scouts pick/take a photo
--    on the Scout page, the site uploads it here, and the field's saved
--    value is just this bucket's public URL for that file.
--
--    Path convention the site uses (not enforced by SQL, just the shape
--    of the keys the policies below match against):
--      <event_id>/<match|pit>/<team_number>/<field_key>-<timestamp>.<ext>
--
--    The bucket is public so a saved photo URL renders directly as an
--    <img>, including on guest share pages, without a signed request.
--
--    Because of that, a file must really be removed once nothing uses it. SQL can't delete
--    Storage files, so triggers below record the path in photo_cleanup_queue when an entry is
--    deleted (including through an event cascade) or its photo replaced. The Scout page and
--    Staff Portal then call photo_cleanup_paths() and remove those files through the Storage API.
-- =====================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('scouting-photos', 'scouting-photos', true, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','image/heif'])
on conflict (id) do update set
  public = true, file_size_limit = 10485760,
  allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic','image/heif'];

drop policy if exists "team uploads scouting photos" on storage.objects;
drop policy if exists "team replaces scouting photos" on storage.objects;
drop policy if exists "anyone views scouting photos" on storage.objects;
drop policy if exists "team lists scouting photos" on storage.objects;
drop policy if exists "staff deletes scouting photos" on storage.objects;
drop policy if exists "team deletes orphaned scouting photos" on storage.objects;

create policy "team uploads scouting photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'scouting-photos' and ((select public.is_staff()) or (select public.is_student())));
-- Re-uploading the same path (upsert, e.g. replacing a pit photo) is an update, not an insert.
-- Students may only overwrite a photo they themselves uploaded (storage.objects.owner is set
-- automatically on insert); staff can replace anyone's, same as everywhere else on this site.
create policy "team replaces scouting photos" on storage.objects for update to authenticated
  using (bucket_id = 'scouting-photos' and ((select public.is_staff()) or ((select public.is_student()) and owner = auth.uid())))
  with check (bucket_id = 'scouting-photos' and ((select public.is_staff()) or ((select public.is_student()) and owner = auth.uid())));
-- Saved photo URLs load for anyone without this policy, because the bucket is public. It only
-- controls listing files through the API, so anonymous visitors can't enumerate every photo.
create policy "team lists scouting photos" on storage.objects for select to authenticated
  using (bucket_id = 'scouting-photos' and ((select public.is_staff()) or (select public.is_student())));
create policy "staff deletes scouting photos" on storage.objects for delete to authenticated
  using (bucket_id = 'scouting-photos' and (select public.is_staff()));

-- Paths waiting to be removed from the bucket. Written by the trigger below, emptied by
-- photo_cleanup_paths(). Never reachable through the API directly.
create table if not exists public.photo_cleanup_queue (
  path      text primary key,
  queued_at timestamptz not null default now()
);
alter table public.photo_cleanup_queue enable row level security;
revoke all on public.photo_cleanup_queue from anon, authenticated;

-- True if any entry still points at this file. Every removal checks this first, so a path that
-- was queued by mistake, or reused by another entry, can never cost a live photo.
create or replace function public.photo_in_use(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.scouting_entries s where position(p_name in s.data::text) > 0)
      or exists (select 1 from public.pit_entries p where position(p_name in p.data::text) > 0);
$$;

-- Queues every photo this row pointed at that its new version (if any) no longer does
create or replace function public.queue_orphaned_photos() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_new text := case when TG_OP = 'UPDATE' then NEW.data::text else '' end;
begin
  insert into public.photo_cleanup_queue (path)
  select m[1]
  from regexp_matches(OLD.data::text, '/storage/v1/object/public/scouting-photos/([A-Za-z0-9_./-]+)', 'g') m
  where position(m[1] in v_new) = 0
  on conflict (path) do nothing;
  return null;
end $$;

drop trigger if exists queue_photos_match on public.scouting_entries;
drop trigger if exists queue_photos_pit   on public.pit_entries;
create trigger queue_photos_match after delete or update of data on public.scouting_entries
  for each row execute function public.queue_orphaned_photos();
create trigger queue_photos_pit after delete or update of data on public.pit_entries
  for each row execute function public.queue_orphaned_photos();

-- Students may delete a pit entry they didn't upload, so they need to be able to remove its file.
-- This limits them to files that are queued and unused; only staff can delete anything else.
create or replace function public.photo_is_orphaned(p_name text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.photo_cleanup_queue q where q.path = p_name)
     and not public.photo_in_use(p_name);
$$;
create policy "team deletes orphaned scouting photos" on storage.objects for delete to authenticated
  using (bucket_id = 'scouting-photos' and (select public.is_student()) and public.photo_is_orphaned(name));

-- Returns up to 500 paths for the caller to remove. First drops anything already gone from the
-- bucket or back in use, so a removal that failed part way simply comes round again next call.
create or replace function public.photo_cleanup_paths() returns text[]
language plpgsql security definer set search_path = '' as $$
declare
  v_paths text[];
begin
  if not (public.is_staff() or public.is_student()) then return '{}'; end if;
  delete from public.photo_cleanup_queue q
   where public.photo_in_use(q.path)
      or not exists (select 1 from storage.objects o where o.bucket_id = 'scouting-photos' and o.name = q.path);
  select coalesce(array_agg(x.path), '{}') into v_paths
    from (select q.path from public.photo_cleanup_queue q order by q.queued_at limit 500) x;
  return v_paths;
end $$;

revoke all on function public.photo_in_use(text) from public, anon, authenticated;
revoke all on function public.photo_is_orphaned(text) from public, anon;
revoke all on function public.photo_cleanup_paths() from public, anon;
grant execute on function public.photo_is_orphaned(text) to authenticated;
grant execute on function public.photo_cleanup_paths() to authenticated;

-- OPTIONAL, ONE TIME: files orphaned before the triggers above existed were never queued. To
-- clear them, preview with the select, then run the insert and open the Staff Portal. This
-- permanently deletes the files, so it's left commented out rather than running on every rebuild.
-- The one-day limit skips a photo that's mid-upload for an entry not saved yet.
--
-- select o.name, o.created_at from storage.objects o
-- where o.bucket_id = 'scouting-photos' and o.created_at < now() - interval '1 day'
--   and not public.photo_in_use(o.name);
--
-- insert into public.photo_cleanup_queue (path)
-- select o.name from storage.objects o
-- where o.bucket_id = 'scouting-photos' and o.created_at < now() - interval '1 day'
--   and not public.photo_in_use(o.name)
-- on conflict (path) do nothing;


-- =====================================================================
-- 10. Guest access: a valid, unrevoked, unexpired code returns the same slice of data the
--     Team Database page (query.html) shows, scoped to the code's events/teams, as one jsonb
--     blob — events, active form fields, every team that has any data in scope (not just one),
--     raw match/pit/official rows, and the same S–F scouting/official grades query.html computes
--     (team_ratings()/team_official_ratings()), recomputed here over just the scoped rows so a
--     guest's percentile is relative to the slice they were given, not the whole team database.
--     Reuses the scoring helpers from section 9 (jnum/jbool/rebuilt_*_points/pit_capability/
--     event_tier_weight) so the math can't drift from the real ratings.
--
--     Any team member or staff can make a code (section 5), since they can already see all of
--     this; it stops working once its creator couldn't (share_code_creator_ok()).
--
--     Codes are short, so guesses are limited: 10 wrong codes in 10 minutes locks that account
--     out for the rest of the window, returning {"error":"rate_limited"}. Test teams are left
--     out unless the code names them, so dummy data never reaches or skews a guest's view.
-- =====================================================================
drop function if exists public.get_shared_scouting(text);
create or replace function public.get_shared_scouting(p_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_event_ids uuid[];
  v_team_numbers int[];
  v_result jsonb;
  v_uid uuid := auth.uid();
begin
  -- A session staff signed out stays valid by signature until it expires, so check it here too.
  -- is_staff()/is_student() check for a ban, but guests never go through those.
  if v_uid is null or not public.session_live() or not exists (
    select 1 from auth.users u
    where u.id = v_uid and u.email_confirmed_at is not null
      and (u.banned_until is null or u.banned_until <= now())
  ) then
    return null;
  end if;

  -- One lookup at a time per account, or parallel requests could all pass the guess count below
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 0));

  delete from public.share_code_attempts where attempted_at < now() - interval '10 minutes';
  if (select count(*) from public.share_code_attempts where user_id = v_uid) >= 10 then
    return jsonb_build_object('error', 'rate_limited');
  end if;

  select c.id, c.event_ids, c.team_numbers into v_id, v_event_ids, v_team_numbers
  from public.share_codes c
  where c.code = p_code
    and not c.revoked
    and (c.expires_at is null or c.expires_at > now())
    and public.share_code_creator_ok(c.created_by)   -- its creator can still see this data
  limit 1;

  if v_id is null then
    insert into public.share_code_attempts (user_id) values (v_uid);
    return null;
  end if;

  -- Every successful lookup counts as one "use" of the code, whether it came from a pasted
  -- code or a scanned QR (both go through this same function) — this is the scan counter
  -- shown on the Share Codes tab.
  update public.share_codes
     set use_count = use_count + 1, last_used_at = now()
   where id = v_id;

  with
  scoped_matches as (
    select s.* from public.scouting_entries s
    where (cardinality(v_event_ids) = 0 or s.event_id = any(v_event_ids))
      and (case when cardinality(v_team_numbers) = 0
             then not exists (select 1 from public.test_teams tt where tt.team_number = s.team_number)
             else s.team_number = any(v_team_numbers) end)
  ),
  scoped_pit as (
    select p.* from public.pit_entries p
    where (cardinality(v_event_ids) = 0 or p.event_id = any(v_event_ids))
      and (case when cardinality(v_team_numbers) = 0
             then not exists (select 1 from public.test_teams tt where tt.team_number = p.team_number)
             else p.team_number = any(v_team_numbers) end)
  ),
  scoped_official as (
    select o.* from public.official_match_teams o
    where (cardinality(v_event_ids) = 0 or o.event_id = any(v_event_ids))
      and (case when cardinality(v_team_numbers) = 0
             then not exists (select 1 from public.test_teams tt where tt.team_number = o.team_number)
             else o.team_number = any(v_team_numbers) end)
  ),
  -- Scouting grade, same math as team_ratings() (section 9) but over scoped_matches/scoped_pit
  -- instead of every match, and with no is_staff()/is_student() gate (the code already proved
  -- access to exactly this slice).
  rate_entries as (
    select m.id, m.event_id, m.match_number, m.team_number, m.data as d,
           public.rebuilt_fuel_points(m.data)  as fuel_pts,
           public.rebuilt_tower_points(m.data) as tower_pts,
           public.rebuilt_auto_points(m.data)  as auto_pts,
           coalesce(m.data ->> 'teleop_role', 'Scorer') not in ('Defense', 'Feeder') as scoring_match
    from scoped_matches m
    where m.data ?| array['stuck_on_field','foul_or_card','auto_fuel_hub','teleop_fuel_hub','auto_tower','teleop_tower']
  ),
  rate_per_match as (
    select e.team_number,
      avg(e.fuel_pts + e.tower_pts) as points,
      avg(e.fuel_pts) filter (where e.scoring_match) as fuel_pts,
      avg(e.tower_pts) as tower_pts,
      avg(e.auto_pts) as auto_pts,
      avg(case public.jbool(e.d, 'auto_mobility') when true then 1 when false then 0 end) as mobility,
      avg(public.jnum(e.d, 'shooter_accuracy')) as accuracy,
      avg(coalesce(public.jnum(e.d, 'teleop_fuel_per_volley'),
                   public.jnum(e.d, 'teleop_fuel_hub') / nullif(public.jnum(e.d, 'teleop_volleys'), 0))) as fpv,
      avg(case when coalesce(public.jbool(e.d, 'robot_disabled'), false) then 1 else 0 end)::numeric as dis,
      avg(case when coalesce(public.jbool(e.d, 'broke_down'), false) then 1 else 0 end)::numeric as broke,
      avg(case when coalesce(public.jbool(e.d, 'stuck_on_field'), false) then 1 else 0 end)::numeric as stuck,
      avg(case when coalesce(public.jbool(e.d, 'foul_or_card'), false) then 1 else 0 end)::numeric as foul
    from rate_entries e
    group by e.team_number, e.event_id, coalesce(e.match_number::text, e.id::text)
  ),
  rate_agg as (
    select m.team_number,
      count(*)::int as matches,
      avg(m.points) as avg_points,
      avg(m.fuel_pts) as fuel_avg,
      avg(m.tower_pts) as tower_avg,
      avg(m.auto_pts) as auto_avg,
      avg(m.mobility) as mobility_rate,
      avg(m.accuracy) as accuracy_avg,
      avg(m.fpv) as fpv_avg,
      avg(m.dis) as dis_rate,
      avg(m.broke) as broke_rate,
      avg(m.stuck) as stuck_rate,
      avg(m.foul) as foul_rate,
      exists (select 1 from public.test_teams tt where tt.team_number = m.team_number) as is_test
    from rate_per_match m
    group by m.team_number
  ),
  rate_pit as (
    select distinct on (p.team_number) p.team_number, public.pit_capability(p.data) as cap
    from scoped_pit p
    order by p.team_number, p.updated_at desc
  ),
  rate_base as (
    select a.*, pit.cap,
      case when a.fuel_avg  is not null then (cume_dist() over (partition by a.is_test, (a.fuel_avg  is not null) order by a.fuel_avg))::numeric end as p_fuel,
      case when a.tower_avg is not null then (cume_dist() over (partition by a.is_test, (a.tower_avg is not null) order by a.tower_avg))::numeric end as p_tower,
      case when a.auto_avg  is not null then (cume_dist() over (partition by a.is_test, (a.auto_avg  is not null) order by a.auto_avg))::numeric end as p_auto,
      case when a.fpv_avg   is not null then (cume_dist() over (partition by a.is_test, (a.fpv_avg   is not null) order by a.fpv_avg))::numeric end as p_fpv
    from rate_agg a
    left join rate_pit pit on pit.team_number = a.team_number
  ),
  rate_comp as (
    select b.*,
      b.p_fuel as c_fuel,
      b.p_tower as c_climb,
      coalesce(0.8 * b.p_auto + 0.2 * b.mobility_rate, b.p_auto) as c_auto,
      (select avg(x) from (values (b.p_fpv), ((b.accuracy_avg - 1) / 4)) v(x)) as c_eff,
      greatest(0, 1 - (b.dis_rate + 0.6 * b.broke_rate + 0.4 * b.stuck_rate)) as c_rel,
      greatest(0, 1 - b.foul_rate) as c_disc,
      b.cap as c_pit
    from rate_base b
  ),
  rate_scored as (
    select c.*,
      100 * (select sum(w * x) / sum(w)
               from (values (32, c.c_fuel), (16, c.c_climb), (9, c.c_auto), (11, c.c_eff),
                            (16, c.c_rel), (5, c.c_disc), (11, c.c_pit)) v(w, x)
              where x is not null) as raw_score
    from rate_comp c
  ),
  rate_ranked as (
    select s.*, (cume_dist() over (partition by s.is_test order by s.raw_score))::numeric as pct
    from rate_scored s
  ),
  scout_grades as (
    select r.team_number, r.matches,
           round(r.avg_points, 2) as avg_points,
           round(r.raw_score, 1) as score,
           case when r.pct >= .90 then 'S' when r.pct >= .75 then 'A' when r.pct >= .50 then 'B'
                when r.pct >= .25 then 'C' when r.pct >= .10 then 'D' else 'F' end as grade,
           round(r.pct, 3) as pct
    from rate_ranked r
  ),
  -- Official grade, same math as team_official_ratings() (section 9): OPR from the cache for the
  -- code's events, ranked among the code's teams. Record and average score from scoped_official.
  off_weighted as (
    select o.team_number, o.alliance_score, o.opponent_score,
           public.event_tier_weight(e.event_tier) as w
    from scoped_official o
    join public.events e on e.id = o.event_id
    where o.alliance_score is not null and o.opponent_score is not null
  ),
  off_agg as (
    select m.team_number,
      count(*)::int as matches,
      count(*) filter (where m.alliance_score > m.opponent_score)::int as wins,
      count(*) filter (where m.alliance_score < m.opponent_score)::int as losses,
      count(*) filter (where m.alliance_score = m.opponent_score)::int as ties,
      sum(m.alliance_score * m.w) / sum(m.w) as avg_score,
      exists (select 1 from public.test_teams tt where tt.team_number = m.team_number) as is_test
    from off_weighted m
    group by m.team_number
  ),
  off_opr as (
    select c.team_number,
           sum(c.opr * public.event_tier_weight(e.event_tier) * c.matches)
             / sum(public.event_tier_weight(e.event_tier) * c.matches) as rating,
           sum(c.matches) as qual_matches
    from public.official_opr_cache c
    join public.events e on e.id = c.event_id
    where (cardinality(v_event_ids) = 0 or c.event_id = any(v_event_ids))
      and c.team_number in (select a.team_number from off_agg a)
    group by c.team_number
  ),
  off_scored as (
    select a.*, case when o.qual_matches >= 3 then o.rating end as rating
    from off_agg a left join off_opr o on o.team_number = a.team_number
  ),
  off_pct as (
    select s.*, case when s.rating is not null then
             (cume_dist() over (partition by s.is_test, s.rating is null order by s.rating))::numeric
           end as pct
    from off_scored s
  ),
  official_grades as (
    select p.team_number, p.matches,
           round(p.avg_score, 2) as avg_score,
           round(p.rating::numeric, 1) as score,
           case when p.pct is null then null
                when p.pct >= .90 then 'S' when p.pct >= .75 then 'A' when p.pct >= .50 then 'B'
                when p.pct >= .25 then 'C' when p.pct >= .10 then 'D' else 'F' end as grade,
           round(p.pct, 3) as pct
    from off_pct p
  ),
  all_teams as (
    select team_number from scoped_matches
    union
    select team_number from scoped_pit
    union
    select team_number from scoped_official
  )
  select jsonb_build_object(
    'events', coalesce((
      select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'event_date', e.event_date))
      from public.events e
      -- A team-only code lists just the events that team has data at, not every event
      where e.id = any(v_event_ids)
         or (cardinality(v_event_ids) = 0 and e.id in (
              select event_id from scoped_matches union
              select event_id from scoped_pit union
              select event_id from scoped_official))
    ), '[]'::jsonb),
    'fields', coalesce((
      select jsonb_agg(jsonb_build_object(
        'key', f.key, 'label', f.label, 'field_type', f.field_type,
        'scope', coalesce(f.scope, 'match'), 'required', f.required,
        'reg_limit', f.reg_limit, 'allow_unsure', f.allow_unsure, 'sort_order', f.sort_order
      ) order by f.sort_order)
      from public.scout_fields f
      where f.active
    ), '[]'::jsonb),
    'teams', coalesce((
      select jsonb_agg(jsonb_build_object(
        'team_number', t.team_number,
        'team_name', ti.display_name,
        'logo_url', ti.display_logo,
        'scout', case when sg.team_number is not null then to_jsonb(sg) - 'team_number' end,
        'official', case when og.team_number is not null then to_jsonb(og) - 'team_number' end
      ))
      from all_teams t
      left join public.team_info ti    on ti.team_number = t.team_number
      left join scout_grades sg        on sg.team_number = t.team_number
      left join official_grades og     on og.team_number = t.team_number
    ), '[]'::jsonb),
    'matches', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_id', m.event_id, 'team_number', m.team_number, 'match_number', m.match_number,
        'data', m.data, 'created_at', m.created_at
      ))
      from scoped_matches m
    ), '[]'::jsonb),
    'pit', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_id', p.event_id, 'team_number', p.team_number, 'data', p.data, 'updated_at', p.updated_at
      ))
      from scoped_pit p
    ), '[]'::jsonb),
    'official', coalesce((
      select jsonb_agg(jsonb_build_object(
        'event_id', o.event_id, 'team_number', o.team_number, 'match_key', o.match_key,
        'comp_level', o.comp_level, 'set_number', o.set_number, 'match_number', o.match_number,
        'alliance', o.alliance, 'alliance_score', o.alliance_score,
        'opponent_score', o.opponent_score, 'played_at', o.played_at
      ))
      from scoped_official o
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

-- Staff Portal's Share Codes tab: same rows as a direct select on share_codes, plus who
-- created each code (needs a join into auth.users, which a plain client select can't do).
-- owner_team and creator_ok were added for member-made codes; older pages ignore them.
drop function if exists public.staff_list_share_codes();
create or replace function public.staff_list_share_codes()
returns table (
  id uuid, code text, label text, event_ids uuid[], team_numbers int[],
  expires_at timestamptz, revoked boolean, created_at timestamptz,
  use_count int, last_used_at timestamptz,
  created_by uuid, created_by_name text, owner_team int, creator_ok boolean
)
language sql stable security definer set search_path = '' as $$
  select c.id, c.code, c.label, c.event_ids, c.team_numbers,
         c.expires_at, c.revoked, c.created_at, c.use_count, c.last_used_at,
         c.created_by,
         coalesce(public.account_name(u.raw_user_meta_data), u.email::text),
         c.owner_team, public.share_code_creator_ok(c.created_by)
  from public.share_codes c
  left join auth.users u on u.id = c.created_by
  where public.is_staff()
  order by c.created_at desc;
$$;

-- Share Data page (share.html): the caller's own codes, plus every code from their team when
-- they manage it. Names only, no emails, as other teams' members don't see each other's.
create or replace function public.list_share_codes()
returns table (
  id uuid, code text, label text, event_ids uuid[], team_numbers int[],
  expires_at timestamptz, revoked boolean, created_at timestamptz,
  use_count int, last_used_at timestamptz,
  mine boolean, created_by_name text, creator_ok boolean
)
language sql stable security definer set search_path = '' as $$
  select c.id, c.code, c.label, c.event_ids, c.team_numbers,
         c.expires_at, c.revoked, c.created_at, c.use_count, c.last_used_at,
         c.created_by = auth.uid(),
         coalesce(public.account_name(u.raw_user_meta_data), 'A former member'),
         public.share_code_creator_ok(c.created_by)
  from public.share_codes c
  left join auth.users u on u.id = c.created_by
  where public.session_live()
    and (c.created_by = auth.uid()
         or (c.owner_team = public.my_team() and public.is_team_manager()))
  order by c.created_at desc;
$$;


-- =====================================================================
-- 11. Account management for the Staff Portal Members tab
-- =====================================================================
-- team_number/team_role: the team the account is on. claim_team/claim_status: what it said
-- (team_claims, section 3b), so staff see who is waiting and who hasn't answered.
drop function if exists public.staff_list_members();
create or replace function public.staff_list_members()
returns table (user_id uuid, email text, display_name text, level text, banned boolean, last_sign_in timestamptz,
               team_number int, team_role text, claim_team int, claim_status text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  return query
    select u.id,
           u.email::text,
           coalesce(public.account_name(u.raw_user_meta_data), '')::text,
           (case
              when s.user_id is not null then 'staff'
              when g.level = 'mentor' and exists (select 1 from public.member_team(u.id)) then 'mentor'
              when exists (select 1 from public.member_team(u.id)) then 'student'
              else 'guest'
            end)::text,
           (u.banned_until is not null and u.banned_until > now()),
           u.last_sign_in_at,
           m.team_number, m.role, c.team_number, c.status
    from auth.users u
    left join public.staff_members s on s.user_id = u.id
    left join public.member_grants g on g.user_id = u.id
    left join lateral public.member_team(u.id) m on true
    left join public.team_claims c on c.user_id = u.id
    order by u.created_at desc;
end $$;

-- Set any account's name, for accounts that never gave one
create or replace function public.staff_set_display_name(target uuid, p_name text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_name  text := btrim(coalesce(p_name, ''));
  v_email text;
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  if char_length(v_name) not between 1 and 60 then raise exception 'Names are 1 to 60 characters.'; end if;
  update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('display_name', v_name)
   where id = target
   returning email into v_email;
  if v_email is null then raise exception 'No such account.'; end if;
  perform public.log_action('update', 'auth.users', target::text, format('Set the name of %s to "%s"', v_email, v_name));
end $$;

-- Set any account's level: 'staff', 'mentor', 'student', or 'guest'
create or replace function public.staff_set_level(target uuid, new_level text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  if new_level not in ('staff','mentor','student','guest') then
    raise exception 'Unknown access level.';
  end if;
  if target = auth.uid() and new_level <> 'staff' then
    raise exception 'You cannot change your own access level.';
  end if;

  if new_level = 'staff' then
    insert into public.staff_members (user_id, note) values (target, 'set from website')
    on conflict (user_id) do nothing;
    delete from public.member_grants where user_id = target;
  else
    if exists (select 1 from public.staff_members where user_id = target) then
      if (select count(*) from public.staff_members) <= 1 then
        raise exception 'Cannot remove the last staff member.';
      end if;
      delete from public.staff_members where user_id = target;
    end if;
    insert into public.member_grants (user_id, level, granted_by)
    values (target, new_level, auth.uid())
    on conflict (user_id) do update
      set level = excluded.level, granted_by = excluded.granted_by, updated_at = now();
    -- Guest means no team at all, including one joined with a code (section 3b). A mentor or
    -- student grant undoes an earlier removal, so the grant puts them on the home team again.
    if new_level = 'guest' then
      update public.team_members set role = 'removed', added_by = auth.uid(), added_at = now()
       where user_id = target and role <> 'removed';
    else
      delete from public.team_members where user_id = target and role = 'removed';
    end if;
  end if;
end $$;

-- Sign someone out everywhere. Deleting the auth.sessions row alone only blocks
-- session_live() for RLS -- it doesn't stop the browser's own background token
-- refresh, which (while the refresh token is still unrevoked) happily mints a
-- brand-new session and silently restores full access. Revoking every refresh
-- token for the user first is what actually makes the kick stick.
create or replace function public.staff_kick(target uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_email text;
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  if target = auth.uid() then raise exception 'You cannot kick yourself.'; end if;
  update auth.refresh_tokens set revoked = true
    where user_id = target::text and revoked = false;
  delete from auth.sessions where user_id = target;
  select email into v_email from auth.users where id = target;
  perform public.log_action('kick', 'auth.sessions', target::text,
    format('Signed out %s everywhere', coalesce(v_email, target::text)));
end $$;


-- =====================================================================
-- 12. Permissions (RLS above still decides which ROWS each person can touch)
--     This project does not hand out table privileges automatically, so
--     every grant the site and the Edge Functions rely on is listed here.
-- =====================================================================

-- 12a. Signed-in users (the website)
grant select, insert, update, delete on public.events           to authenticated;
grant select, insert, update, delete on public.scouting_entries to authenticated;
grant select, insert, update, delete on public.scout_fields     to authenticated;
grant select, insert, update, delete on public.share_codes      to authenticated;
grant select, insert, update, delete on public.pit_entries      to authenticated;
grant select, insert, update, delete on public.test_teams       to authenticated;
grant select, insert, update, delete on public.team_info        to authenticated;
grant select, insert, update, delete on public.playoff_picks    to authenticated;
grant select, insert, update, delete on public.playoff_tiebreaks to authenticated;
grant select, insert, update, delete on public.playoff_lineups  to authenticated;
grant select, insert, update, delete on public.match_schedule   to authenticated;
grant select, insert, update, delete on public.match_flag_reviews to authenticated;
grant select, insert, update, delete on public.match_strategies to authenticated;
grant select, insert, update, delete on public.alliance_strategies to authenticated;
grant select, insert, update, delete on public.scout_shifts     to authenticated;
grant select, insert, update, delete on public.pick_list        to authenticated;
grant select, insert, update, delete on public.robot_log        to authenticated;
grant select on public.teams                     to authenticated;
grant select on public.team_claims               to authenticated;
grant select on public.team_domains              to authenticated;
grant select, delete on public.team_invites      to authenticated;
grant select, insert, update, delete on public.team_join_codes to authenticated;
grant select, delete on public.team_manager_requests to authenticated;
grant select on public.match_predictions         to authenticated;
grant select on public.push_subscriptions        to authenticated;
revoke all on public.match_alerts_sent from anon, authenticated;
grant select on public.vision_matches            to authenticated;
grant select on public.vision_robots             to authenticated;
grant select on public.official_matches          to authenticated;
grant select on public.official_matches_combined to authenticated;
grant select on public.official_team_matches     to authenticated;
grant select on public.official_match_teams      to authenticated;

revoke all on function public.session_live()                from public, anon;
revoke all on function public.is_staff()                   from public, anon;
revoke all on function public.is_student()                 from public, anon;
revoke all on function public.my_access_level()            from public, anon;
revoke all on function public.staff_list_members()         from public, anon;
revoke all on function public.staff_set_level(uuid, text)  from public, anon;
revoke all on function public.staff_kick(uuid)             from public, anon;
revoke all on function public.staff_set_display_name(uuid, text) from public, anon;
revoke all on function public.account_name(jsonb)          from public, anon;
revoke all on function public.team_ratings()               from public, anon;
revoke all on function public.team_points_summary()        from public, anon;
revoke all on function public.team_official_ratings()      from public, anon;
revoke all on function public.event_tier_weight(text)      from public, anon;
revoke all on function public.team_official_summary()      from public, anon;
revoke all on function public.official_match_teams_for(int[])  from public, anon;
revoke all on function public.official_lineups_for(int[])       from public, anon;
revoke all on function public.team_data_counts()           from public, anon;
revoke all on function public.official_ratings_compute()   from public, anon, authenticated;
revoke all on function public.official_summary_compute()   from public, anon, authenticated;
revoke all on function public.refresh_official_cache(boolean) from public, anon, authenticated;
revoke all on function public.official_opr_fill(uuid[])    from public, anon, authenticated;
revoke all on function public.official_cache_touch()       from public, anon, authenticated;
revoke all on function public.official_matches_changed()   from public, anon, authenticated;
revoke all on function public.official_matches_truncated() from public, anon, authenticated;
revoke all on function public.official_matches_skip_unchanged() from public, anon, authenticated;
revoke all on function public.pit_capability(jsonb)        from public, anon;
revoke all on function public.get_shared_scouting(text)    from public, anon;
revoke all on function public.staff_list_share_codes()     from public, anon;
revoke all on function public.list_share_codes()           from public, anon;
revoke all on function public.validate_data(jsonb, text)    from public, anon;
revoke all on function public.gen_share_code()              from public, anon;
revoke all on function public.team_member_names(uuid[])     from public, anon;
revoke all on function public.log_prediction(uuid, text, int[], int[], numeric, numeric, numeric) from public, anon;
revoke all on function public.prediction_calibration()      from public, anon;
revoke all on function public.push_subscribe(text, text, text, int) from public, anon;
revoke all on function public.push_unsubscribe(text)        from public, anon;
revoke all on function public.relay_scouting_entry(jsonb)   from public, anon;
revoke all on function public.public_team_results()         from public;
revoke all on function public.home_team()                   from public, anon;
revoke all on function public.my_team()                     from public, anon;
revoke all on function public.is_team_manager()             from public, anon;
revoke all on function public.team_feature_default(text)    from public, anon;
revoke all on function public.team_can(text)                from public, anon;
revoke all on function public.gen_join_code()               from public, anon;
revoke all on function public.my_team_info()                from public, anon;
revoke all on function public.my_alliance(uuid, text)       from public, anon;
revoke all on function public.team_roster()                 from public, anon;
revoke all on function public.team_set_role(uuid, text)     from public, anon;
revoke all on function public.team_leave()                  from public, anon;
revoke all on function public.join_team(text)               from public, anon;
revoke all on function public.team_update_settings(jsonb)   from public, anon;
revoke all on function public.request_team_manager(int, text, text) from public, anon;
revoke all on function public.staff_list_team_requests()    from public, anon;
revoke all on function public.staff_review_team_request(bigint, boolean, text) from public, anon;
revoke all on function public.staff_list_teams()            from public, anon;
revoke all on function public.staff_set_team_role(uuid, int, text) from public, anon;
revoke all on function public.staff_set_team_domain(int, text) from public, anon;
revoke all on function public.require_team_claims() from public, anon;
revoke all on function public.is_free_email_domain(text) from public, anon;
revoke all on function public.claim_team(int) from public, anon;
revoke all on function public.team_pending_claims() from public, anon;
revoke all on function public.verify_team_claim(uuid, boolean, text, text) from public, anon;
revoke all on function public.staff_list_claims() from public, anon;
revoke all on function public.team_add_domain(text) from public, anon;
revoke all on function public.team_remove_domain(text) from public, anon;
revoke all on function public.team_invite(text, text) from public, anon;
revoke all on function public.accept_team_invite(bigint) from public, anon;
revoke all on function public.decline_team_invite(bigint) from public, anon;
revoke all on function public.staff_act_as_team(int) from public, anon;
revoke all on function public.staff_set_require_claims(boolean) from public, anon;

grant execute on function public.session_live()                to authenticated;
grant execute on function public.is_staff()                   to authenticated;
grant execute on function public.is_student()                 to authenticated;
grant execute on function public.my_access_level()            to authenticated;
grant execute on function public.staff_list_members()         to authenticated;
grant execute on function public.staff_set_level(uuid, text)  to authenticated;
grant execute on function public.staff_kick(uuid)             to authenticated;
grant execute on function public.staff_set_display_name(uuid, text) to authenticated;
grant execute on function public.account_name(jsonb)          to authenticated;
grant execute on function public.team_points_summary()        to authenticated;
grant execute on function public.team_ratings()               to authenticated;
grant execute on function public.team_official_ratings()      to authenticated;
grant execute on function public.event_tier_weight(text)      to authenticated;
grant execute on function public.team_official_summary()      to authenticated;
grant execute on function public.official_match_teams_for(int[])  to authenticated;
grant execute on function public.official_lineups_for(int[])       to authenticated;
grant execute on function public.team_data_counts()           to authenticated;
grant execute on function public.get_shared_scouting(text)    to authenticated;
grant execute on function public.staff_list_share_codes()     to authenticated;
grant execute on function public.list_share_codes()           to authenticated;
grant execute on function public.validate_data(jsonb, text)   to authenticated;
grant execute on function public.gen_share_code()             to authenticated;
grant execute on function public.team_member_names(uuid[])    to authenticated;
grant execute on function public.log_prediction(uuid, text, int[], int[], numeric, numeric, numeric) to authenticated;
grant execute on function public.prediction_calibration()     to authenticated;
grant execute on function public.push_subscribe(text, text, text, int) to authenticated;
grant execute on function public.push_unsubscribe(text)       to authenticated;
grant execute on function public.relay_scouting_entry(jsonb)  to authenticated;
-- Teams (section 3b)
grant execute on function public.home_team()                  to authenticated;
grant execute on function public.my_team()                    to authenticated;
grant execute on function public.is_team_manager()            to authenticated;
grant execute on function public.team_feature_default(text)   to authenticated;
grant execute on function public.team_can(text)               to authenticated;
grant execute on function public.gen_join_code()              to authenticated;
grant execute on function public.my_team_info()               to authenticated;
grant execute on function public.my_alliance(uuid, text)      to authenticated;
grant execute on function public.team_roster()                to authenticated;
grant execute on function public.team_set_role(uuid, text)    to authenticated;
grant execute on function public.team_leave()                 to authenticated;
grant execute on function public.join_team(text)              to authenticated;
grant execute on function public.team_update_settings(jsonb)  to authenticated;
grant execute on function public.request_team_manager(int, text, text) to authenticated;
grant execute on function public.staff_list_team_requests()   to authenticated;
grant execute on function public.staff_review_team_request(bigint, boolean, text) to authenticated;
grant execute on function public.staff_list_teams()           to authenticated;
grant execute on function public.staff_set_team_role(uuid, int, text) to authenticated;
grant execute on function public.staff_set_team_domain(int, text) to authenticated;
grant execute on function public.require_team_claims() to authenticated;
grant execute on function public.is_free_email_domain(text) to authenticated;
grant execute on function public.claim_team(int) to authenticated;
grant execute on function public.team_pending_claims() to authenticated;
grant execute on function public.verify_team_claim(uuid, boolean, text, text) to authenticated;
grant execute on function public.staff_list_claims() to authenticated;
grant execute on function public.team_add_domain(text) to authenticated;
grant execute on function public.team_remove_domain(text) to authenticated;
grant execute on function public.team_invite(text, text) to authenticated;
grant execute on function public.accept_team_invite(bigint) to authenticated;
grant execute on function public.decline_team_invite(bigint) to authenticated;
grant execute on function public.staff_act_as_team(int) to authenticated;
grant execute on function public.staff_set_require_claims(boolean) to authenticated;
-- The public Season Results page calls this without signing in (section 8s)
grant execute on function public.public_team_results()        to anon, authenticated;

-- 12b. The Edge Functions (official-sync, manage-member) connect as service_role.
--      It skips row security but still needs table privileges. Without these
--      the sync fails with "permission denied for table events".
grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;


-- =====================================================================
-- 13. Form fields
-- =====================================================================

-- 13a. 2025 fields, retired but kept so old entries still validate and keep their points
insert into public.scout_fields (key, label, field_type, min_value, max_value, section, sort_order, active, scope, is_points) values
  ('auto_points',      '2025: Auto points',      'number',  0,    500, 'Auto',    1,  false, 'match', true),
  ('teleop_points',    '2025: Teleop points',    'number',  0,    500, 'Teleop',  2,  false, 'match', true),
  ('endgame',          '2025: Endgame',          'text',    null, null, 'Endgame', 3,  false, 'match', false),
  ('endgame_points',   '2025: Endgame points',   'number',  0,    100, 'Endgame', 30, false, 'match', true),
  ('endgame_achieved', '2025: Endgame achieved', 'boolean', null, null, 'Endgame', 31, false, 'match', false),
  ('can_climb',        '2025: Can climb',        'boolean', null, null, 'Endgame', 40, false, 'pit',   false)
on conflict (key) do update set active = false;

-- 13b. 2026 REBUILT match scouting
-- Scouts record approximate counts and climb levels. rebuilt_points() turns them into points.
-- A volley is one burst of shooting at the HUB. Volley count and FUEL per volley come first, so
-- the Scout page can autofill the FUEL total from them (staying editable by hand — see the
-- autofill comment in scout.html); the total itself is ordered right after.
-- Keys reused from earlier seasons keep their saved values.
insert into public.scout_fields
  (key, label, field_type, options, min_value, max_value, required, section, sort_order, active, scope, is_points, reg_limit, allow_unsure) values
  ('auto_mobility',          'Left starting zone (auto)',                 'boolean', null, null, null, false, 'Autonomous', 10, true, 'match', false, null, false),
  ('auto_volleys',           'Volley count (auto)',                       'number',  null, 0,    20,   false, 'Autonomous', 11, true, 'match', false, null, false),
  ('auto_fuel_per_volley',   'Approx. FUEL per volley (auto)',            'number',  null, 0,    100,  false, 'Autonomous', 12, true, 'match', false, null, false),
  ('auto_fuel_hub',          'Approx. FUEL scored in HUB (auto)',         'number',  null, 0,    200,  false, 'Autonomous', 13, true, 'match', false, null, false),
  ('auto_tower',             'TOWER climb (auto)',                        'choice',  array['None','L1'], null, null, false, 'Autonomous', 14, true, 'match', false, null, false),
  ('teleop_volleys',         'Volley count (teleop)',                     'number',  null, 0,    100,  false, 'Teleop',  20, true, 'match', false, null, false),
  ('teleop_fuel_per_volley', 'Approx. FUEL per volley (teleop)',          'number',  null, 0,    100,  false, 'Teleop',  21, true, 'match', false, null, false),
  ('teleop_fuel_hub',        'Approx. FUEL scored in ACTIVE HUB (teleop)','number',  null, 0,    500,  false, 'Teleop',  22, true, 'match', false, null, false),
  ('teleop_fuel_source',     'Main FUEL source',                          'choice',  array['Neutral zone','Depot','Outpost','Multiple'], null, null, false, 'Teleop', 23, true, 'match', false, null, false),
  ('teleop_role',            'Primary role',                              'choice',  array['Scorer','Feeder','Defense','Mixed'], null, null, false, 'Teleop', 24, true, 'match', false, null, false),
  ('shooter_accuracy',       'Shooting accuracy',                         'slider',  null, 1,    5,    false, 'Teleop',  25, true, 'match', false, null, false),
  ('stuck_on_field',         'Got stuck on a BUMP or in a TRENCH',        'boolean', null, null, null, false, 'Teleop',  26, true, 'match', false, null, false),
  ('teleop_tower',           'TOWER climb (teleop)',                      'choice',  array['None','L1','L2','L3'], null, null, false, 'Endgame', 30, true, 'match', false, null, false),
  ('foul_or_card',           'Committed a foul or card',                  'boolean', null, null, null, false, 'Match Events', 40, true, 'match', false, null, false),
  ('robot_disabled',         'Robot disabled during match',               'boolean', null, null, null, false, 'Match Events', 41, true, 'match', false, null, false),
  ('broke_down',             'Broke down / needed help',                  'boolean', null, null, null, false, 'Match Events', 42, true, 'match', false, null, false),
  ('match_notes',            'Notes',                                     'text',    null, null, null, false, 'Match Events', 50, true, 'match', false, null, false)
on conflict (key) do update set
  label = excluded.label, field_type = excluded.field_type, options = excluded.options,
  min_value = excluded.min_value, max_value = excluded.max_value, required = excluded.required,
  section = excluded.section, sort_order = excluded.sort_order, active = excluded.active,
  scope = excluded.scope, is_points = excluded.is_points,
  reg_limit = excluded.reg_limit, allow_unsure = excluded.allow_unsure;

-- 13c. 2026 REBUILT pit scouting (limits from manual R103, R104, R107, and the TRENCH clearance)
-- robot_photo is the picture field: scouts attach a photo of the team's robot from the Scout
-- page; the value saved is that photo's public URL in the scouting-photos bucket (section 9b).
-- Frame height and weight carry a reg_limit instead of a hard max_value: a robot a little over
-- spec is still a real, savable scouting entry, just one flagged everywhere it's shown (the
-- Scout page's pit form and tables, and the Team Database) rather than rejected outright.
-- shooter_max_range_ft allows "Unsure" (allow_unsure) since a scout often can't tell a robot's
-- actual max range just by watching it.
insert into public.scout_fields
  (key, label, field_type, options, min_value, max_value, required, section, sort_order, active, scope, is_points, reg_limit, allow_unsure) values
  ('robot_photo',          'Robot photo',                             'image',   null, null, null, false, 'Robot Photo',       1,  true, 'pit', false, null, false),
  ('frame_length_in',      'Frame length (in)',                       'number',  null, 0, null, false, 'Frame & Weight',     10, true, 'pit', false, null, false),
  ('frame_width_in',       'Frame width (in)',                        'number',  null, 0, null, false, 'Frame & Weight',     11, true, 'pit', false, null, false),
  ('frame_height_in',      'Starting height (in)',                    'number',  null, 0, null, false, 'Frame & Weight',     12, true, 'pit', false, 30,   false),
  ('weight_lb',            'Weight (lb)',                             'number',  null, 0, null, false, 'Frame & Weight',     13, true, 'pit', false, 115,  false),
  ('drivetrain',           'Drivetrain',                              'choice',  array['Swerve','Tank','West Coast','Mecanum','Other'], null, null, false, 'Drivetrain', 20, true, 'pit', false, null, false),
  ('trench_capable',       'Fits under a TRENCH (22.25 in clearance)','boolean', null, null, null, false, 'Drivetrain', 21, true, 'pit', false, null, false),
  ('intake_type',          'Ground intake',                           'choice',  array['Front','Side','Front and side','None'], null, null, false, 'Intake', 30, true, 'pit', false, null, false),
  ('fuel_capacity',        'Max FUEL it can hold',                    'number',  null, 0, 100, false, 'Intake',     31, true, 'pit', false, null, false),
  ('shooter_type',         'Shooter type',                            'choice',  array['Fixed flywheel','Adjustable hood','Turret','Other'], null, null, false, 'Shooter', 40, true, 'pit', false, null, false),
  ('shooter_max_range_ft', 'Max shooting range (ft)',                 'number',  null, 0, 60,  false, 'Shooter',    41, true, 'pit', false, null, true),
  ('tower_max_level',      'Highest TOWER level climbed',             'choice',  array['None','L1','L2','L3'], null, null, false, 'Climbing', 50, true, 'pit', false, null, false),
  ('uses_vision',          'Uses AprilTag vision',                    'boolean', null, null, null, false, 'Strategy & Vision', 60, true, 'pit', false, null, false),
  ('auto_strategy',        'Auto routine (notes)',                    'text',    null, null, null, false, 'Strategy & Vision', 61, true, 'pit', false, null, false),
  ('pit_notes',            'Pit notes',                               'text',    null, null, null, false, 'Pit Notes',  70, true, 'pit', false, null, false)
on conflict (key) do update set
  label = excluded.label, field_type = excluded.field_type, options = excluded.options,
  min_value = excluded.min_value, max_value = excluded.max_value, required = excluded.required,
  section = excluded.section, sort_order = excluded.sort_order, active = excluded.active,
  scope = excluded.scope, is_points = excluded.is_points,
  reg_limit = excluded.reg_limit, allow_unsure = excluded.allow_unsure;


-- =====================================================================
-- 14. First staff member (safe to re-run). The person must have signed
--     up on the site and confirmed their email first, otherwise this
--     inserts nothing.
-- =====================================================================
insert into public.staff_members (user_id, note)
select id, 'Danny' from auth.users
where lower(email) = 'dmartinl878@gmail.com'
on conflict (user_id) do nothing;
-- The site owner's own account isn't asked which team it's on (section 3b)
update public.staff_members set no_team_prompt = true
where user_id = (select id from auth.users where lower(email) = 'dmartinl878@gmail.com') and not no_team_prompt;

-- To add or remove staff later:
-- insert into public.staff_members (user_id, note)
-- select id, 'Name' from auth.users where lower(email) = 'someone@example.com'
-- on conflict (user_id) do nothing;
--
-- delete from public.staff_members
-- where user_id = (select id from auth.users where lower(email) = 'someone@example.com');


-- =====================================================================
-- 15. OPTIONAL: automatic official-data sync (run after the database is
--     built, and after deploying the official-sync Edge Function)
--
--     Edge Function setup (terminal, or the same in Dashboard > Edge Functions):
--       supabase functions deploy official-sync --no-verify-jwt
--       supabase functions deploy official-alliances --no-verify-jwt   (this repo, supabase/functions)
--       supabase secrets set FRC_API_USER=... FRC_API_TOKEN=... TBA_API_KEY=... SYNC_SECRET=...
--       (EVENT_TZ is optional; default America/New_York)
--     The function must be deployed with JWT verification OFF; it checks
--     the secret or a staff login itself. manage-member is a separate function.
--
--     Polls FRC Events + TBA every 2 minutes. The function skips events that
--     aren't within a day before to four days after their date, and events
--     synced less than 90 seconds ago, so this is cheap on quiet days.
--
--     1. Dashboard > Database > Extensions: enable pg_cron and pg_net.
--     2. Store the secret once (same value as the SYNC_SECRET function secret):
--          select vault.create_secret('PASTE_SYNC_SECRET_HERE', 'sync_secret');
--     3. Uncomment and run:
--
-- select cron.schedule('official-sync', '*/2 * * * *', $job$
--   select net.http_post(
--     url     := 'https://nyanwljgsazwuzmnlrcz.supabase.co/functions/v1/official-sync',
--     headers := jsonb_build_object(
--                  'Content-Type', 'application/json',
--                  'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'sync_secret')),
--     body    := '{}'::jsonb);
-- $job$);
--
--     To stop it:  select cron.unschedule('official-sync');
--
--     Competition-day auto-sync: refreshes the one event staff picked with the
--     clock button in the Staff Portal, at every even minute of the clock
--     (9:30, 9:32, 9:34...). It does nothing while no event is picked, so it
--     can stay scheduled all season. The block below turns on pg_cron and pg_net
--     and schedules it every time this file runs. Only step 2's vault secret is
--     left to do by hand, because a secret can't live in this file. The check
--     query in section 17 shows whether both are in place.
--
--     To stop it:  select cron.unschedule('auto-sync-event');
--
--     Match alerts (section 8q) need the match-alerts Edge Function (supabase/functions) and
--     its VAPID keys; see the comment at the top of its index.ts. The job is scheduled below.
--     To stop it:  select cron.unschedule('match-alerts');
-- =====================================================================
do $$
begin
  begin
    create extension if not exists pg_cron with schema pg_catalog;
    create extension if not exists pg_net with schema extensions;
  exception when others then
    raise warning 'Could not enable pg_cron/pg_net: %. Enable them in Dashboard > Database > Extensions.', sqlerrm;
  end;
  if to_regnamespace('cron') is not null then
    -- Same job name replaces the old schedule, so this is safe to re-run
    perform cron.schedule('auto-sync-event', '*/2 * * * *', 'select public.run_auto_sync()');
    -- Rebuilds the official rating cache (section 9) within 3 minutes of any change. Not every
    -- minute: the database is on the smallest compute, and logins share its disk IO budget.
    perform cron.schedule('refresh-official-cache', '*/3 * * * *', 'select public.refresh_official_cache()');
    -- Match alerts (section 8q), on the odd minutes so each run sees the sync just before it.
    -- Does nothing unless auto-sync is on and someone turned alerts on.
    perform cron.schedule('match-alerts', '1-59/2 * * * *', 'select public.run_match_alerts()');
    -- pg_cron logs every run and never prunes, so keep two days (auto_sync_health reads the latest)
    perform cron.schedule('cron-history-cleanup', '17 4 * * *',
      $job$delete from cron.job_run_details where end_time < now() - interval '2 days'$job$);
  end if;
end $$;

-- Fill the official rating cache now, so ratings show straight after this file runs
select public.refresh_official_cache(true);


-- =====================================================================
-- 16. Audit log: who did what, when, and whether they were acting as
--     staff, a mentor/student, a guest, or the system (Edge Functions).
--
--     Most rows are written automatically by audit_row_change(), a
--     generic trigger attached below to every table whose changes are
--     worth a record (events, scouting/pit entries, form fields, share
--     codes, staff/member grants, team info). A couple of actions that
--     don't correspond to a table write (signing someone out) call
--     public.log_action() directly instead — see staff_kick() in
--     section 11, above. The manage-member Edge Function (ban/unban,
--     not in this repo) should do the same on success: call
--     `select public.log_action('ban'|'unban', 'auth.users', target,
--     '<summary>')` over its service-role connection, which already has
--     execute on every function per section 12b.
--
--     Rows are kept for 6 months. purge_old_audit_log() below removes anything older, and
--     log_action() calls it on every write, so this needs no scheduled job. To change the
--     retention period, edit the interval in that function.
--
--     Only staff can read the log (policy below); everyone else can
--     write to it only indirectly, through the security definer
--     functions here, never through a direct insert.
-- =====================================================================
create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  actor_id    uuid references auth.users(id) on delete set null,
  actor_email text,
  actor_role  text not null check (actor_role in ('staff','mentor','student','guest','system')),
  action      text not null check (action in ('insert','update','delete','kick','ban','unban')),
  table_name  text,
  record_id   text,
  summary     text not null check (char_length(summary) <= 300),
  details     jsonb
);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon, authenticated;

create index if not exists audit_log_created_idx on public.audit_log (created_at desc);
create index if not exists audit_log_actor_idx   on public.audit_log (actor_id);
create index if not exists audit_log_role_idx    on public.audit_log (actor_role);

drop policy if exists "staff read audit log" on public.audit_log;
create policy "staff read audit log" on public.audit_log for select to authenticated
  using ((select public.is_staff()));

-- Deletes audit rows past the retention period. The created_at index makes this a quick no-op
-- when nothing has expired. Not logged itself, and not callable from the API.
create or replace function public.purge_old_audit_log() returns void
language sql security definer set search_path = '' as $$
  delete from public.audit_log where created_at < now() - interval '6 months';
$$;

-- Central write helper. Every writer below (the generic trigger, staff_kick(), the
-- manage-member Edge Function) calls this rather than inserting into audit_log
-- directly, so actor_role is always worked out the same way. It must stay uncallable from
-- the API: security definer callers and service_role reach it, signed-in users don't.
create or replace function public.log_action(
  p_action text, p_table text, p_record_id text, p_summary text, p_details jsonb default null
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_role  text;
  v_email text;
begin
  if auth.uid() is null then
    v_role := 'system'; -- Edge Functions call this connected as service_role, no auth.uid()
  else
    v_role := coalesce(public.my_access_level(), 'guest');
    if v_role = 'student' and exists (
      select 1 from public.member_grants where user_id = auth.uid() and level = 'mentor'
    ) then
      v_role := 'mentor';
    end if;
    select email into v_email from auth.users where id = auth.uid();
  end if;
  insert into public.audit_log (actor_id, actor_email, actor_role, action, table_name, record_id, summary, details)
  values (auth.uid(), v_email, v_role, p_action, p_table, p_record_id, left(p_summary, 300), p_details);
  perform public.purge_old_audit_log();
end $$;

-- Generic row-change logger, attached as an AFTER trigger to every audited table.
-- Builds a readable summary per table from the changed row's own jsonb shape, so one
-- function covers every table without a column list to keep in sync. Record id falls
-- back through every primary key shape used in this schema (id, user_id, team_number).
create or replace function public.audit_row_change() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_row     jsonb;
  v_id      text;
  v_summary text;
  v_verb    text;
  v_sync_cols constant text[] := array['official_synced_at', 'tba_etag', 'frc_last_modified',
                                       'official_sync_status', 'official_sync_note', 'auto_sync_request',
                                       'resync_request', 'resync_requested_at'];
  v_tba_cols constant text[] := array['tba_name', 'tba_logo_url', 'tba_checked_at', 'display_name', 'display_logo'];
begin
  -- A share-code redemption only bumps its counters. Logging that would add a row per use.
  if TG_TABLE_NAME in ('share_codes', 'team_join_codes') and TG_OP = 'UPDATE'
     and to_jsonb(NEW) - 'use_count' - 'last_used_at' = to_jsonb(OLD) - 'use_count' - 'last_used_at' then
    return NEW;
  end if;

  -- Same for a sync's bookkeeping columns, or auto-sync would add a row every 2 minutes.
  if TG_TABLE_NAME = 'events' and TG_OP = 'UPDATE'
     and to_jsonb(NEW) - v_sync_cols = to_jsonb(OLD) - v_sync_cols then
    return NEW;
  end if;

  -- Same for team names and logos filled in from TBA: a row holding only those isn't a staff change.
  if TG_TABLE_NAME = 'team_info'
     and ((TG_OP = 'UPDATE' and to_jsonb(NEW) - v_tba_cols = to_jsonb(OLD) - v_tba_cols)
       or (TG_OP = 'INSERT' and to_jsonb(NEW) ->> 'team_name' is null and to_jsonb(NEW) ->> 'logo_url' is null)) then
    return NEW;
  end if;

  v_row  := to_jsonb(case when TG_OP = 'DELETE' then OLD else NEW end);
  v_id   := coalesce(v_row ->> 'id', v_row ->> 'user_id', v_row ->> 'team_number', v_row ->> 'match_key', '');
  v_verb := initcap(lower(TG_OP));
  v_summary := case TG_TABLE_NAME
    when 'events' then
      format('%s event "%s"', v_verb, v_row ->> 'name')
    when 'scouting_entries' then
      format('%s scouting entry: team %s, match %s', v_verb, v_row ->> 'team_number', coalesce(v_row ->> 'match_number', '?'))
    when 'pit_entries' then
      format('%s pit entry: team %s', v_verb, v_row ->> 'team_number')
    when 'scout_fields' then
      format('%s form field "%s"', v_verb, v_row ->> 'label')
    when 'share_codes' then
      format('%s share code "%s"%s', v_verb, v_row ->> 'label',
        case when v_row ->> 'owner_team' is not null then ' (team ' || (v_row ->> 'owner_team') || ')' else '' end)
    when 'team_info' then
      format('%s team info: team %s', v_verb, v_row ->> 'team_number')
    when 'playoff_picks' then
      format('%s playoff pick: team %s, alliance %s', v_verb, v_row ->> 'team_number', v_row ->> 'alliance_number')
    when 'playoff_tiebreaks' then
      format('%s tiebreak: %s won by alliance %s', v_verb, v_row ->> 'match_key', v_row ->> 'winner_alliance')
    when 'playoff_lineups' then
      format('%s line-up: team %s sits out %s for alliance %s', v_verb, v_row ->> 'sits_out', v_row ->> 'match_key', v_row ->> 'alliance_number')
    when 'match_schedule' then
      format('%s schedule: %s, red %s, blue %s', v_verb, v_row ->> 'match_key', v_row ->> 'red_teams', v_row ->> 'blue_teams')
    when 'match_strategies' then
      format('%s strategy plan: %s', v_verb, v_row ->> 'match_key')
    when 'alliance_strategies' then
      format('%s %s alliance plan: %s', v_verb, v_row ->> 'alliance', v_row ->> 'match_key')
    when 'scout_shifts' then
      format('%s scout shift: %s, quals %s-%s', v_verb, v_row ->> 'station', v_row ->> 'first_match', v_row ->> 'last_match')
    when 'pick_list' then
      format('%s pick list: team %s', v_verb, v_row ->> 'team_number')
    when 'robot_log' then
      format('%s robot log: %s', v_verb, v_row ->> 'kind')
    when 'match_flag_reviews' then
      format('%s flag review: %s, team %s, %s marked %s', v_verb, v_row ->> 'match_key', v_row ->> 'team_number',
        v_row ->> 'flag_type', v_row ->> 'status')
    when 'staff_members' then
      format('%s staff member %s', v_verb,
        coalesce((select email from auth.users where id = (v_row ->> 'user_id')::uuid), v_row ->> 'user_id'))
    when 'teams' then
      format('%s team %s', case TG_OP when 'INSERT' then 'Verified' when 'DELETE' then 'Removed' else 'Updated settings for' end,
        v_row ->> 'team_number')
    when 'team_members' then
      format('%s team %s role: %s -> %s', v_verb, v_row ->> 'team_number',
        coalesce((select email from auth.users where id = (v_row ->> 'user_id')::uuid), v_row ->> 'user_id'),
        v_row ->> 'role')
    when 'team_join_codes' then
      format('%s join code for team %s%s', v_verb, v_row ->> 'team_number',
        case when (v_row ->> 'revoked')::boolean then ' (revoked)' else '' end)
    when 'team_claims' then
      format('Team claim: %s says team %s, %s%s',
        coalesce((select email from auth.users where id = (v_row ->> 'user_id')::uuid), v_row ->> 'user_id'),
        coalesce(v_row ->> 'team_number', 'none'), v_row ->> 'status',
        case when v_row ->> 'how' is not null then ' (' || (v_row ->> 'how') || ')' else '' end)
    when 'team_domains' then
      format('%s domain %s for team %s', v_verb, v_row ->> 'domain', v_row ->> 'team_number')
    when 'team_invites' then
      format('%s invitation to team %s as %s', v_verb, v_row ->> 'team_number', v_row ->> 'role')
    when 'app_settings' then
      format('Quarantine for unverified team claims turned %s',
        case when (v_row ->> 'require_team_claims')::boolean then 'on' else 'off' end)
    when 'team_manager_requests' then
      format('%s request to manage team %s: %s', v_verb, v_row ->> 'team_number', v_row ->> 'status')
    when 'member_grants' then
      format('%s access grant: %s -> %s', v_verb,
        coalesce((select email from auth.users where id = (v_row ->> 'user_id')::uuid), v_row ->> 'user_id'),
        v_row ->> 'level')
    else
      format('%s %s', v_verb, TG_TABLE_NAME)
  end;
  perform public.log_action(lower(TG_OP), TG_TABLE_NAME, v_id, v_summary,
    jsonb_build_object('old', to_jsonb(OLD), 'new', to_jsonb(NEW)));
  return case when TG_OP = 'DELETE' then OLD else NEW end;
end $$;

drop trigger if exists audit_events         on public.events;
drop trigger if exists audit_scouting       on public.scouting_entries;
drop trigger if exists audit_pit            on public.pit_entries;
drop trigger if exists audit_fields         on public.scout_fields;
drop trigger if exists audit_codes          on public.share_codes;
drop trigger if exists audit_team_info      on public.team_info;
drop trigger if exists audit_playoff_picks  on public.playoff_picks;
drop trigger if exists audit_playoff_tiebreaks on public.playoff_tiebreaks;
drop trigger if exists audit_playoff_lineups on public.playoff_lineups;
drop trigger if exists audit_match_schedule on public.match_schedule;
drop trigger if exists audit_flag_reviews   on public.match_flag_reviews;
drop trigger if exists audit_match_strategies on public.match_strategies;
drop trigger if exists audit_alliance_strategies on public.alliance_strategies;
drop trigger if exists audit_scout_shifts   on public.scout_shifts;
drop trigger if exists audit_pick_list      on public.pick_list;
drop trigger if exists audit_robot_log      on public.robot_log;
drop trigger if exists audit_staff_members  on public.staff_members;
drop trigger if exists audit_member_grants  on public.member_grants;
drop trigger if exists audit_teams          on public.teams;
drop trigger if exists audit_team_members   on public.team_members;
drop trigger if exists audit_team_join_codes on public.team_join_codes;
drop trigger if exists audit_team_requests  on public.team_manager_requests;
drop trigger if exists audit_team_claims    on public.team_claims;
drop trigger if exists audit_team_domains   on public.team_domains;
drop trigger if exists audit_team_invites   on public.team_invites;
drop trigger if exists audit_app_settings   on public.app_settings;
create trigger audit_events        after insert or update or delete on public.events          for each row execute function public.audit_row_change();
create trigger audit_scouting      after insert or update or delete on public.scouting_entries for each row execute function public.audit_row_change();
create trigger audit_pit           after insert or update or delete on public.pit_entries      for each row execute function public.audit_row_change();
create trigger audit_fields        after insert or update or delete on public.scout_fields     for each row execute function public.audit_row_change();
create trigger audit_codes         after insert or update or delete on public.share_codes      for each row execute function public.audit_row_change();
create trigger audit_team_info     after insert or update or delete on public.team_info        for each row execute function public.audit_row_change();
create trigger audit_playoff_picks after insert or update or delete on public.playoff_picks    for each row execute function public.audit_row_change();
create trigger audit_playoff_tiebreaks after insert or update or delete on public.playoff_tiebreaks for each row execute function public.audit_row_change();
create trigger audit_playoff_lineups after insert or update or delete on public.playoff_lineups for each row execute function public.audit_row_change();
create trigger audit_match_schedule after insert or update or delete on public.match_schedule   for each row execute function public.audit_row_change();
create trigger audit_flag_reviews   after insert or update or delete on public.match_flag_reviews for each row execute function public.audit_row_change();
-- Plans save as people draw, so only making and removing one is logged, not every change
create trigger audit_match_strategies after insert or delete on public.match_strategies for each row execute function public.audit_row_change();
create trigger audit_alliance_strategies after insert or delete on public.alliance_strategies for each row execute function public.audit_row_change();
create trigger audit_scout_shifts   after insert or update or delete on public.scout_shifts     for each row execute function public.audit_row_change();
-- A reorder rewrites every row's rank, so only adding and removing teams is logged
create trigger audit_pick_list      after insert or delete on public.pick_list                  for each row execute function public.audit_row_change();
create trigger audit_robot_log      after delete on public.robot_log                            for each row execute function public.audit_row_change();
create trigger audit_staff_members after insert or update or delete on public.staff_members     for each row execute function public.audit_row_change();
create trigger audit_member_grants after insert or update or delete on public.member_grants     for each row execute function public.audit_row_change();
create trigger audit_teams         after insert or update or delete on public.teams             for each row execute function public.audit_row_change();
create trigger audit_team_members  after insert or update or delete on public.team_members      for each row execute function public.audit_row_change();
-- A redemption only bumps use_count, which is left out like a share code's (above)
create trigger audit_team_join_codes after insert or update or delete on public.team_join_codes for each row execute function public.audit_row_change();
create trigger audit_team_requests after insert or update or delete on public.team_manager_requests for each row execute function public.audit_row_change();
create trigger audit_team_claims   after insert or update or delete on public.team_claims       for each row execute function public.audit_row_change();
create trigger audit_team_domains  after insert or delete on public.team_domains                for each row execute function public.audit_row_change();
create trigger audit_team_invites  after insert or delete on public.team_invites                for each row execute function public.audit_row_change();
create trigger audit_app_settings  after update on public.app_settings                          for each row execute function public.audit_row_change();

-- Powerful search for the Staff Portal's Audit Log tab: free-text search plus filters,
-- all optional and combinable. p_search matches the summary, actor email, table name,
-- record id, and the raw before/after details.
create or replace function public.staff_search_audit_log(
  p_search text default null,
  p_role   text default null,
  p_action text default null,
  p_table  text default null,
  p_since  timestamptz default null,
  p_until  timestamptz default null,
  p_limit  int default 200,
  p_offset int default 0
) returns table (
  id bigint, created_at timestamptz, actor_email text, actor_role text,
  action text, table_name text, record_id text, summary text, details jsonb
)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  return query
    select a.id, a.created_at, a.actor_email, a.actor_role, a.action, a.table_name, a.record_id, a.summary, a.details
    from public.audit_log a
    where (p_role   is null or a.actor_role = p_role)
      and (p_action is null or a.action = p_action)
      and (p_table  is null or a.table_name = p_table)
      and (p_since  is null or a.created_at >= p_since)
      and (p_until  is null or a.created_at <= p_until)
      and (
        p_search is null or p_search = '' or
        a.summary     ilike '%' || p_search || '%' or
        a.actor_email ilike '%' || p_search || '%' or
        a.table_name  ilike '%' || p_search || '%' or
        a.record_id   ilike '%' || p_search || '%' or
        a.details::text ilike '%' || p_search || '%'
      )
    order by a.created_at desc
    limit least(coalesce(p_limit, 200), 500) offset greatest(coalesce(p_offset, 0), 0);
end $$;

revoke all on function public.log_action(text, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.log_action(text, text, text, text, jsonb) to service_role;
revoke all on function public.purge_old_audit_log() from public, anon, authenticated;

-- Clear anything already past the retention period when this file is run
select public.purge_old_audit_log();
revoke all on function public.staff_search_audit_log(text, text, text, text, timestamptz, timestamptz, int, int) from public, anon;
grant execute on function public.staff_search_audit_log(text, text, text, text, timestamptz, timestamptz, int, int) to authenticated;

-- Removes everything a banned or deleted account entered, in one transaction. Pit entries
-- are matched on scouted_by, which is the last editor, so one a teammate has since edited stays.
-- Returns the scouting-photos paths the caller must remove through the Storage API (SQL can't
-- delete the files). Photos still used by a surviving entry are left alone. Rows already removed
-- don't affect the result, so a failed photo cleanup can be retried. The audit triggers keep a
-- staff-only copy of each deleted row. Must stay uncallable from the API: service_role only.
create or replace function public.purge_member_data(target uuid, p_reason text)
returns text[] language plpgsql security definer set search_path = '' as $$
declare
  v_match int;
  v_pit   int;
  v_paths text[];
  v_email text;
begin
  delete from public.scouting_entries where scouted_by = target;
  get diagnostics v_match = row_count;
  delete from public.pit_entries where scouted_by = target;
  get diagnostics v_pit = row_count;
  delete from public.match_flag_reviews where reviewed_by = target;
  delete from public.robot_log where created_by = target;
  delete from public.scout_shifts where user_id = target;
  delete from public.push_subscriptions where user_id = target;
  update public.share_codes set revoked = true where created_by = target and not revoked;

  select coalesce(array_agg(o.name), '{}') into v_paths
    from storage.objects o
    where o.bucket_id = 'scouting-photos' and o.owner = target
      and not exists (select 1 from public.scouting_entries s where position(o.name in s.data::text) > 0)
      and not exists (select 1 from public.pit_entries p where position(o.name in p.data::text) > 0);

  select email into v_email from auth.users where id = target;
  perform public.log_action('delete', 'auth.users', target::text,
    format('Removed data for %s (%s): %s match entries, %s pit entries, %s photos',
      coalesce(v_email, target::text), p_reason, v_match, v_pit, cardinality(v_paths)));
  return v_paths;
end $$;
revoke all on function public.purge_member_data(uuid, text) from public, anon, authenticated;
grant execute on function public.purge_member_data(uuid, text) to service_role;


-- =====================================================================
-- 16b. Teams, step 2: per-team keys for strategy plans and the pick list
--
--     Until this runs, match_strategies and pick_list keep their old primary keys
--     (event_id, match_key) and (event_id, team_number), so two teams can't both have a plan
--     for the same match, or the same team on their pick lists. The old keys stay because the
--     stable release's pages save against them. Once a release with the Teams change is on
--     stable (see RELEASING.md), uncomment this block, run it, and commit it uncommented.
--     Don't verify a second team before then.
-- =====================================================================
-- do $$
-- begin
--   if exists (select 1 from pg_constraint where conname = 'match_strategies_pkey'
--              and conrelid = 'public.match_strategies'::regclass
--              and pg_get_constraintdef(oid) not like '%owner_team%') then
--     alter table public.match_strategies drop constraint match_strategies_pkey;
--     alter table public.match_strategies add constraint match_strategies_pkey
--       primary key using index match_strategies_team_key;
--   end if;
--   if exists (select 1 from pg_constraint where conname = 'pick_list_pkey'
--              and conrelid = 'public.pick_list'::regclass
--              and pg_get_constraintdef(oid) not like '%owner_team%') then
--     alter table public.pick_list drop constraint pick_list_pkey;
--     alter table public.pick_list add constraint pick_list_pkey
--       primary key using index pick_list_team_key;
--   end if;
-- end $$;


-- =====================================================================
-- 17. Check query. Run this last (or any time). The result lists every
--     expected table, view, function, and the photo storage bucket;
--     "present" should be true on every row. Rows that are false sort
--     to the top.
-- =====================================================================
with expected(kind, name) as (values
  ('table','events'), ('table','scouting_entries'), ('table','scout_fields'),
  ('table','pit_entries'), ('table','share_codes'), ('table','staff_members'),
  ('table','member_grants'), ('table','official_matches'), ('table','test_teams'),
  ('table','team_info'), ('table','playoff_picks'), ('table','playoff_tiebreaks'), ('table','playoff_lineups'), ('table','match_schedule'), ('table','audit_log'), ('table','share_code_attempts'), ('table','photo_cleanup_queue'),
  ('table','vision_matches'), ('table','vision_robots'), ('table','match_flag_reviews'), ('table','match_strategies'),
  ('table','scout_shifts'), ('table','pick_list'), ('table','match_predictions'), ('table','robot_log'),
  ('table','push_subscriptions'), ('table','match_alerts_sent'),
  ('table','alliance_strategies'), ('function','match_alliance'), ('function','my_alliance'),
  ('table','team_claims'), ('table','team_domains'), ('table','team_invites'), ('table','app_settings'),
  ('function','claim_team'), ('function','verify_team_claim'), ('function','team_pending_claims'),
  ('function','team_add_domain'), ('function','team_invite'), ('function','accept_team_invite'),
  ('function','staff_act_as_team'), ('function','staff_set_require_claims'), ('function','legacy_team'),
  ('table','teams'), ('table','team_members'), ('table','team_join_codes'), ('table','team_manager_requests'),
  ('function','member_team'), ('function','my_team'), ('function','is_team_manager'), ('function','team_can'),
  ('function','my_team_info'), ('function','team_roster'), ('function','team_set_role'), ('function','team_leave'),
  ('function','join_team'), ('function','team_update_settings'), ('function','request_team_manager'),
  ('function','staff_list_team_requests'), ('function','staff_review_team_request'), ('function','staff_list_teams'),
  ('function','staff_set_team_role'), ('function','staff_set_team_domain'),
  ('function','is_team_member'), ('function','team_member_names'), ('function','log_prediction'),
  ('function','prediction_calibration'), ('function','push_subscribe'), ('function','push_unsubscribe'),
  ('function','run_match_alerts'), ('function','relay_scouting_entry'), ('function','public_team_results'),
  ('view','official_matches_combined'), ('view','official_team_matches'),
  ('view','official_match_teams'), ('function','official_match_teams_for'), ('function','official_lineups_for'),
  ('function','is_staff'), ('function','is_student'), ('function','my_access_level'), ('function','official_set_alliances'),
  ('function','session_live'),
  ('function','staff_list_members'), ('function','staff_set_level'), ('function','staff_kick'),
  ('function','account_name'), ('function','staff_set_display_name'),
  ('function','validate_data'), ('function','team_ratings'), ('function','team_points_summary'),
  ('function','team_official_ratings'), ('function','event_tier_weight'), ('function','team_official_summary'),
  ('function','team_data_counts'), ('function','team_lists'), ('function','get_shared_scouting'),
  ('table','official_ratings_cache'), ('table','official_summary_cache'), ('function','refresh_official_cache'),
  ('table','official_opr_cache'), ('function','official_opr_fill'),
  ('table','official_cache_dirty'), ('function','official_matches_skip_unchanged'), ('function','official_matches_changed'),
  ('function','staff_list_share_codes'), ('function','list_share_codes'), ('function','share_code_creator_ok'),
  ('function','share_codes_guard'), ('function','set_default_event'),
  ('function','set_auto_sync_event'), ('function','run_auto_sync'), ('function','auto_sync_health'),
  ('function','official_sync_request'), ('function','resync_default_event'), ('function','resync_status'),
  ('auto-sync setup','cron_job'), ('auto-sync setup','vault_secret'),
  ('function','photo_cleanup_paths'), ('function','photo_is_orphaned'), ('function','photo_in_use'),
  ('function','log_action'), ('function','purge_old_audit_log'), ('function','staff_search_audit_log'),
  ('bucket','scouting-photos'), ('bucket','team-logos')
)
select e.kind, e.name,
       case e.kind
         when 'function' then exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = e.name)
         when 'bucket'   then exists (select 1 from storage.buckets where id = e.name)
         when 'auto-sync setup' then coalesce((public.auto_sync_health() ->> e.name)::boolean, false)
         else to_regclass('public.' || e.name) is not null
       end as present
from expected e
order by present, e.kind, e.name;
