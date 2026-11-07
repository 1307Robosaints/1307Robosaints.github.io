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
--   4  Form fields (incl. picture fields)     9  Team rating (A-F grade)
--   5  Events, entries, share codes          9b Storage: scouting photos
--   6  Pit entries + validation             10  Guest access via share codes
--  8e  Test teams                           11  Member management (Staff Portal)
--  8f  Team info (names/logos)               8g  Storage: team logos
--  12  Permissions   13  Form field seed data   14  First staff member
--  15  Optional: schedule the automatic sync    16  Audit log
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
-- 2026 REBUILT update: scout_fields.field_type now also accepts 'image',
-- so staff can add a field ("Robot photo", scope = pit) that lets scouts
-- attach a picture of a team's robot from the Scout page. The photo itself
-- is stored in the "scouting-photos" Storage bucket created in section 9b;
-- the entry's data just holds that photo's public URL as a string.
--
-- Later update: events now have an event_tier ('offseason', 'qualifier',
-- 'district_championship', or 'championship'), set per event in the Staff
-- Portal. team_official_ratings() (section 9) weights each match by its
-- event's tier via event_tier_weight() — a win or a high score at a
-- District Championship or the FIRST Championship counts for more than
-- the same result at a regular qualifier, and an off-season result
-- counts for a little less.
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
-- 2. Staff allowlist. Only the SQL Editor can change this table.
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

-- Student = verified, not banned, current session not kicked, and either a grant or a
-- school login. A 'guest' grant turns off the school-domain rule for that account.
create or replace function public.is_student() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from auth.users u
    left join public.member_grants g on g.user_id = u.id
    where u.id = auth.uid()
      and u.email_confirmed_at is not null
      and (u.banned_until is null or u.banned_until <= now())
      and (
        g.level in ('mentor','student')
        or (lower(u.email) like '%@stalux.org' and coalesce(g.level, '') <> 'guest')
      )
  ) and public.session_live();
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
  using (public.is_staff() or public.is_student());
create policy "staff writes fields" on public.scout_fields for all to authenticated
  using (public.is_staff()) with check (public.is_staff());


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
language plpgsql security definer set search_path = public as $$
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

-- Share codes: each can scope to several events and/or several teams at once (arrays, so a
-- code for a whole alliance or a multi-event invite doesn't need to be recreated per
-- event/team), revocable, optional expiry. created_by ties the code to the staff account that
-- made it; use_count/last_used_at track how many times it's actually been redeemed (bumped by
-- get_shared_scouting() in section 10, which is how a QR scan or pasted code shows up here).
create table if not exists public.share_codes (
  id uuid primary key default gen_random_uuid(),
  code text not null unique default substr(replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''), 1, 24),
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
  using (public.is_staff()) with check (public.is_staff());

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
  using (public.is_staff() or public.is_student());
create policy "team adds pit" on public.pit_entries for insert to authenticated
  with check ((public.is_staff() or public.is_student()) and scouted_by = auth.uid());
create policy "team edits pit" on public.pit_entries for update to authenticated
  using (public.is_staff() or public.is_student())
  with check (public.is_staff() or public.is_student());
create policy "team deletes pit" on public.pit_entries for delete to authenticated
  using (public.is_staff() or public.is_student());

-- Every key must belong to the entry's scope. Inactive fields are still accepted,
-- so old entries keep saving. Active fields are checked for type, range, choices,
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
declare f record; v jsonb; txt text; k text; base_key text;
begin
  if jsonb_typeof(p_data) <> 'object' then
    raise exception 'Entry data must be an object';
  end if;

  for k in select jsonb_object_keys(p_data) loop
    if exists (select 1 from public.scout_fields sf where sf.key = k and sf.scope = p_scope) then
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
    -- A field marked "Unsure" via its __unsure companion key is deliberately left blank —
    -- skip the usual required/type checks on the number itself.
    if f.field_type in ('number','slider') and f.allow_unsure
       and coalesce((p_data ->> (f.key || '__unsure'))::boolean, false) then
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
      if jsonb_typeof(v) <> 'string' or char_length(txt) > 2000
         or txt !~ '^https://[a-z0-9-]+\.supabase\.co/storage/v1/object/public/scouting-photos/'
      then raise exception '% must be a photo uploaded through the scouting-photos bucket', f.label; end if;
    end if;
  end loop;
end $$;

create or replace function public.validate_entry() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform public.validate_data(new.data, 'match');
  return new;
end $$;

drop trigger if exists validate_entry on public.scouting_entries;
create trigger validate_entry before insert or update on public.scouting_entries
  for each row execute function public.validate_entry();

create or replace function public.validate_pit_entry() returns trigger
language plpgsql set search_path = '' as $$
begin
  perform public.validate_data(new.data, 'pit');
  return new;
end $$;

drop trigger if exists validate_pit_entry on public.pit_entries;
create trigger validate_pit_entry before insert or update on public.pit_entries
  for each row execute function public.validate_pit_entry();


-- =====================================================================
-- 7. Policies for events and match entries
-- =====================================================================
alter table public.events enable row level security;
alter table public.scouting_entries enable row level security;

drop policy if exists "staff and students read events" on public.events;
drop policy if exists "staff add events"               on public.events;
drop policy if exists "staff edit events"              on public.events;
drop policy if exists "staff deletes events"           on public.events;
create policy "staff and students read events" on public.events for select to authenticated
  using (public.is_staff() or public.is_student());
create policy "staff add events" on public.events for insert to authenticated
  with check (public.is_staff());
create policy "staff edit events" on public.events for update to authenticated
  using (public.is_staff());
create policy "staff deletes events" on public.events for delete to authenticated
  using (public.is_staff());

drop policy if exists "staff and students read entries" on public.scouting_entries;
drop policy if exists "team adds entries"               on public.scouting_entries;
drop policy if exists "team edits own entries"          on public.scouting_entries;
drop policy if exists "staff edits any entry"           on public.scouting_entries;
drop policy if exists "team deletes own entries"        on public.scouting_entries;
drop policy if exists "staff deletes any entry"         on public.scouting_entries;
create policy "staff and students read entries" on public.scouting_entries for select to authenticated
  using (public.is_staff() or public.is_student());
create policy "team adds entries" on public.scouting_entries for insert to authenticated
  with check ((public.is_staff() or public.is_student()) and scouted_by = auth.uid());
create policy "team edits own entries" on public.scouting_entries for update to authenticated
  using ((public.is_staff() or public.is_student()) and scouted_by = auth.uid())
  with check (scouted_by = auth.uid());
create policy "staff edits any entry" on public.scouting_entries for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
create policy "team deletes own entries" on public.scouting_entries for delete to authenticated
  using ((public.is_staff() or public.is_student()) and scouted_by = auth.uid());
create policy "staff deletes any entry" on public.scouting_entries for delete to authenticated
  using (public.is_staff());


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
alter table public.official_matches enable row level security;

drop policy if exists "team reads official matches" on public.official_matches;
create policy "team reads official matches" on public.official_matches for select to authenticated
  using (public.is_staff() or public.is_student());

-- 8a. One row per match. FRC Events is the authority for scores; TBA fills in when FRC has
--     nothing yet. sources shows where the row came from; scores_agree is false if the two
--     sources disagree.
create or replace view public.official_matches_combined with (security_invoker = true) as
select
  coalesce(f.event_id, t.event_id)         as event_id,
  coalesce(f.match_key, t.match_key)       as match_key,
  coalesce(f.comp_level, t.comp_level)     as comp_level,
  coalesce(f.set_number, t.set_number)     as set_number,
  coalesce(f.match_number, t.match_number) as match_number,
  coalesce(f.played_at, t.played_at)       as played_at,
  coalesce(f.red_teams, t.red_teams)       as red_teams,
  coalesce(f.blue_teams, t.blue_teams)     as blue_teams,
  coalesce(f.red_score, t.red_score)       as red_score,
  coalesce(f.blue_score, t.blue_score)     as blue_score,
  coalesce(t.red_breakdown, f.red_breakdown)   as red_breakdown,
  coalesce(t.blue_breakdown, f.blue_breakdown) as blue_breakdown,
  case when f.id is not null and t.id is not null then 'frc+tba'
       when f.id is not null then 'frc' else 'tba' end as sources,
  case when f.id is not null and t.id is not null
       then f.red_score is not distinct from t.red_score and f.blue_score is not distinct from t.blue_score
       end as scores_agree
from (select * from public.official_matches where source = 'frc') f
full join (select * from public.official_matches where source = 'tba') t
  on t.event_id = f.event_id and t.match_key = f.match_key;

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

-- 8d. Per-team official summary (matches played, wins, average alliance score)
--     for the Team Database list.
create or replace function public.team_official_summary()
returns table (team_number int, matches int, wins int, avg_alliance_score numeric)
language sql stable security definer set search_path = '' as $$
  select o.team_number,
         count(*)::int,
         count(*) filter (where o.alliance_score > o.opponent_score)::int,
         round(avg(o.alliance_score), 2)
  from public.official_match_teams o
  where o.alliance_score is not null
    and (public.is_staff() or public.is_student())
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
  using (public.is_staff() or public.is_student());
create policy "staff manages test teams" on public.test_teams for all to authenticated
  using (public.is_staff()) with check (public.is_staff());


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

drop policy if exists "team reads team info"   on public.team_info;
drop policy if exists "staff manages team info" on public.team_info;
create policy "team reads team info" on public.team_info for select to authenticated
  using (public.is_staff() or public.is_student());
create policy "staff manages team info" on public.team_info for all to authenticated
  using (public.is_staff()) with check (public.is_staff());


-- =====================================================================
-- 8g. Storage: team logos
--
--    Backs the logo-upload option on the Team Info tab (section 8f).
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
drop policy if exists "staff deletes team logos" on storage.objects;

create policy "staff uploads team logos" on storage.objects for insert to authenticated
  with check (bucket_id = 'team-logos' and public.is_staff());
create policy "staff replaces team logos" on storage.objects for update to authenticated
  using (bucket_id = 'team-logos' and public.is_staff())
  with check (bucket_id = 'team-logos' and public.is_staff());
create policy "anyone views team logos" on storage.objects for select
  using (bucket_id = 'team-logos');
create policy "staff deletes team logos" on storage.objects for delete to authenticated
  using (bucket_id = 'team-logos' and public.is_staff());


-- =====================================================================
-- 9. Team rating (the A-F grade)
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
--      11  Robot capability  pit form: climb level, trench fit, intake, shooter, drivetrain, vision
--
--    Matches where the scout marked the role as Defense or Feeder are left out of
--    the FUEL-scoring average, so a good defender isn't graded as a bad scorer.
--    Letter grade = where the score ranks among rated teams:
--      S top 10%, A next 15%, B next 25%, C next 25%, D next 15%, F bottom 10%.
--    Not graded (informational only): main FUEL source, volley count, notes, robot photo.
--    To change the weights, edit the numbers in the (w, c) list near the end of team_ratings().
--
--    team_official_ratings(): a single-metric ranking (no components to
--    blend) from FRC Events / TBA results — 60% average alliance score
--    (ranked against other teams), 40% win rate (a tie counts as half a win),
--    with each match first weighted by its event's tier (event_tier_weight(),
--    just above the function): 2.0x at the FIRST Championship, 1.5x at a
--    District Championship, 1.0x at a regular qualifier, 0.75x off-season.
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
    select s.team_number, s.data as d,
           public.rebuilt_fuel_points(s.data)  as fuel_pts,
           public.rebuilt_tower_points(s.data) as tower_pts,
           public.rebuilt_auto_points(s.data)  as auto_pts,
           coalesce(s.data ->> 'teleop_role', 'Scorer') not in ('Defense', 'Feeder') as scoring_match
    from public.scouting_entries s
    where (public.is_staff() or public.is_student())
      and s.data ?| array['stuck_on_field','foul_or_card','auto_fuel_hub','teleop_fuel_hub','auto_tower','teleop_tower']
  ),
  agg as (
    select e.team_number,
      count(*)::int as matches,
      count(*) filter (where coalesce(public.jbool(e.d, 'robot_disabled'), false))::int as disabled_matches,
      avg(e.fuel_pts + e.tower_pts)                         as avg_points,
      avg(e.fuel_pts) filter (where e.scoring_match)        as fuel_avg,
      avg(e.tower_pts)                                      as tower_avg,
      avg(e.auto_pts)                                       as auto_avg,
      avg(case public.jbool(e.d, 'auto_mobility') when true then 1 when false then 0 end) as mobility_rate,
      avg(public.jnum(e.d, 'shooter_accuracy'))             as accuracy_avg,
      avg(coalesce(public.jnum(e.d, 'teleop_fuel_per_volley'),
                   public.jnum(e.d, 'teleop_fuel_hub') / nullif(public.jnum(e.d, 'teleop_volleys'), 0))) as fpv_avg,
      avg(case when coalesce(public.jbool(e.d, 'robot_disabled'), false) then 1 else 0 end)::numeric as dis_rate,
      avg(case when coalesce(public.jbool(e.d, 'broke_down'), false) then 1 else 0 end)::numeric     as broke_rate,
      avg(case when coalesce(public.jbool(e.d, 'stuck_on_field'), false) then 1 else 0 end)::numeric as stuck_rate,
      avg(case when coalesce(public.jbool(e.d, 'foul_or_card'), false) then 1 else 0 end)::numeric   as foul_rate
    from entries e
    group by e.team_number
  ),
  pit as (
    select distinct on (p.team_number) p.team_number, public.pit_capability(p.data) as cap
    from public.pit_entries p
    where public.is_staff() or public.is_student()
    order by p.team_number, p.updated_at desc
  ),
  base as (
    select a.*, pit.cap,
      case when a.fuel_avg  is not null then (cume_dist() over (partition by (a.fuel_avg  is not null) order by a.fuel_avg))::numeric end as p_fuel,
      case when a.tower_avg is not null then (cume_dist() over (partition by (a.tower_avg is not null) order by a.tower_avg))::numeric end as p_tower,
      case when a.auto_avg  is not null then (cume_dist() over (partition by (a.auto_avg  is not null) order by a.auto_avg))::numeric end as p_auto,
      case when a.fpv_avg   is not null then (cume_dist() over (partition by (a.fpv_avg   is not null) order by a.fpv_avg))::numeric end as p_fpv
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
    select s.*, (cume_dist() over (order by s.raw_score))::numeric as pct
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

-- Official rating: the same shape and grading rule as team_ratings(), but scored purely from
-- synced FRC Events / TBA results — 60% average alliance score (ranked against other teams)
-- plus 40% win rate (a tie counts as half a win), with each match weighted by how strong its
-- event is (event_tier_weight() above). Entirely independent of scouting data.
create or replace function public.team_official_ratings()
returns table (team_number int, matches int, wins int, losses int, ties int,
               avg_alliance_score numeric, score numeric, grade text, percentile numeric)
language sql stable security definer set search_path = '' as $$
  with weighted as (
    select o.team_number, o.alliance_score, o.opponent_score,
           public.event_tier_weight(e.event_tier) as w
    from public.official_team_matches o
    join public.events e on e.id = o.event_id
    where public.is_staff() or public.is_student()
  ),
  agg as (
    select m.team_number,
      count(*)::int as matches,
      count(*) filter (where m.alliance_score > m.opponent_score)::int as wins,
      count(*) filter (where m.alliance_score < m.opponent_score)::int as losses,
      count(*) filter (where m.alliance_score = m.opponent_score)::int as ties,
      sum(m.alliance_score * m.w) / sum(m.w) as avg_score,
      sum((case when m.alliance_score > m.opponent_score then 1
                when m.alliance_score = m.opponent_score then .5 else 0 end) * m.w) / sum(m.w) as win_rate
    from weighted m
    group by m.team_number
  ),
  ranked as (
    select a.*, (cume_dist() over (order by a.avg_score))::numeric as p_score
    from agg a
  ),
  scored as (
    select r.*, 100 * (0.6 * r.p_score + 0.4 * r.win_rate) as raw_score
    from ranked r
  ),
  pct as (
    select s.*, (cume_dist() over (order by s.raw_score))::numeric as pct
    from scored s
  )
  select p.team_number, p.matches, p.wins, p.losses, p.ties,
         round(p.avg_score, 2), round(p.raw_score, 1),
         case when p.pct >= .90 then 'S' when p.pct >= .75 then 'A' when p.pct >= .50 then 'B'
              when p.pct >= .25 then 'C' when p.pct >= .10 then 'D' else 'F' end,
         round(p.pct, 3)
  from pct p;
$$;

-- Per-team counters for the Team Database's data-source breakdown: how many matches came from
-- scouting, how many from official sync, and how many matches have BOTH (so the page can show
-- its numbers don't silently double anything). A match counts as overlapping only when a scouted
-- entry and an official qualification-match result agree on the same event and match number.
create or replace function public.team_data_counts()
returns table (team_number int, scouted_matches int, official_matches int, overlap_matches int)
language sql stable security definer set search_path = '' as $$
  with scouted as (
    select s.team_number, count(distinct s.match_number)::int as n
    from public.scouting_entries s
    where (public.is_staff() or public.is_student()) and s.match_number is not null
    group by s.team_number
  ),
  officials as (
    select o.team_number, count(*)::int as n
    from public.official_team_matches o
    where public.is_staff() or public.is_student()
    group by o.team_number
  ),
  overlap as (
    select s.team_number, count(distinct s.match_number)::int as n
    from public.scouting_entries s
    join public.official_team_matches o
      on o.team_number = s.team_number
     and o.event_id = s.event_id
     and o.match_number = s.match_number
     and o.comp_level = 'qm'
    where (public.is_staff() or public.is_student()) and s.match_number is not null
    group by s.team_number
  )
  select coalesce(sc.team_number, off.team_number, ov.team_number),
         coalesce(sc.n, 0), coalesce(off.n, 0), coalesce(ov.n, 0)
  from scouted sc
  full join officials off on off.team_number = sc.team_number
  full join overlap ov on ov.team_number = coalesce(sc.team_number, off.team_number);
$$;


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
drop policy if exists "staff deletes scouting photos" on storage.objects;

create policy "team uploads scouting photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'scouting-photos' and (public.is_staff() or public.is_student()));
-- Re-uploading the same path (upsert, e.g. replacing a pit photo) is an update, not an insert.
-- Students may only overwrite a photo they themselves uploaded (storage.objects.owner is set
-- automatically on insert); staff can replace anyone's, same as everywhere else on this site.
create policy "team replaces scouting photos" on storage.objects for update to authenticated
  using (bucket_id = 'scouting-photos' and (public.is_staff() or (public.is_student() and owner = auth.uid())))
  with check (bucket_id = 'scouting-photos' and (public.is_staff() or (public.is_student() and owner = auth.uid())));
create policy "anyone views scouting photos" on storage.objects for select
  using (bucket_id = 'scouting-photos');
create policy "staff deletes scouting photos" on storage.objects for delete to authenticated
  using (bucket_id = 'scouting-photos' and public.is_staff());


-- =====================================================================
-- 10. Guest access: a valid, unrevoked, unexpired code returns matching entries (read-only)
-- =====================================================================
drop function if exists public.get_shared_scouting(text);
create or replace function public.get_shared_scouting(p_code text)
returns table (event_name text, event_date date, team_number int, match_number int,
               data jsonb, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  select c.id into v_id
  from public.share_codes c
  where c.code = p_code
    and not c.revoked
    and (c.expires_at is null or c.expires_at > now())
  limit 1;

  if v_id is null then
    return;
  end if;

  -- Every successful lookup counts as one "use" of the code, whether it came from a pasted
  -- code or a scanned QR (both go through this same function) — this is the scan counter
  -- shown on the Share Codes tab.
  update public.share_codes
     set use_count = use_count + 1, last_used_at = now()
   where id = v_id;

  return query
    select e.name, e.event_date, s.team_number, s.match_number, s.data, s.created_at
    from public.share_codes c
    join public.scouting_entries s
      on (cardinality(c.event_ids) = 0 or s.event_id = any(c.event_ids))
     and (cardinality(c.team_numbers) = 0 or s.team_number = any(c.team_numbers))
    join public.events e on e.id = s.event_id
    where c.id = v_id
    order by e.event_date nulls last, s.team_number, s.match_number nulls last
    limit 1000;
end;
$$;

-- Staff Portal's Share Codes tab: same rows as a direct select on share_codes, plus who
-- created each code (needs a join into auth.users, which a plain client select can't do).
drop function if exists public.staff_list_share_codes();
create or replace function public.staff_list_share_codes()
returns table (
  id uuid, code text, label text, event_ids uuid[], team_numbers int[],
  expires_at timestamptz, revoked boolean, created_at timestamptz,
  use_count int, last_used_at timestamptz,
  created_by uuid, created_by_name text
)
language sql stable security definer set search_path = '' as $$
  select c.id, c.code, c.label, c.event_ids, c.team_numbers,
         c.expires_at, c.revoked, c.created_at, c.use_count, c.last_used_at,
         c.created_by,
         coalesce(nullif(u.raw_user_meta_data ->> 'display_name', ''), u.email::text)
  from public.share_codes c
  left join auth.users u on u.id = c.created_by
  where public.is_staff()
  order by c.created_at desc;
$$;


-- =====================================================================
-- 11. Account management for the Staff Portal Members tab
-- =====================================================================
create or replace function public.staff_list_members()
returns table (user_id uuid, email text, display_name text, level text, banned boolean, last_sign_in timestamptz)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  return query
    select u.id,
           u.email::text,
           coalesce(u.raw_user_meta_data ->> 'display_name', '')::text,
           (case
              when s.user_id is not null then 'staff'
              when g.level in ('mentor','student') then g.level
              when g.level = 'guest' then 'guest'
              when lower(u.email) like '%@stalux.org' then 'student'
              else 'guest'
            end)::text,
           (u.banned_until is not null and u.banned_until > now()),
           u.last_sign_in_at
    from auth.users u
    left join public.staff_members s on s.user_id = u.id
    left join public.member_grants g on g.user_id = u.id
    order by u.created_at desc;
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
  end if;
end $$;

-- Sign someone out everywhere
create or replace function public.staff_kick(target uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_email text;
begin
  if not public.is_staff() then raise exception 'Staff only.'; end if;
  if target = auth.uid() then raise exception 'You cannot kick yourself.'; end if;
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
revoke all on function public.team_ratings()               from public, anon;
revoke all on function public.team_points_summary()        from public, anon;
revoke all on function public.team_official_ratings()      from public, anon;
revoke all on function public.event_tier_weight(text)      from public, anon;
revoke all on function public.team_official_summary()      from public, anon;
revoke all on function public.team_data_counts()           from public, anon;
revoke all on function public.pit_capability(jsonb)        from public, anon;
revoke all on function public.get_shared_scouting(text)    from public, anon;
revoke all on function public.staff_list_share_codes()     from public, anon;

grant execute on function public.session_live()                to authenticated;
grant execute on function public.is_staff()                   to authenticated;
grant execute on function public.is_student()                 to authenticated;
grant execute on function public.my_access_level()            to authenticated;
grant execute on function public.staff_list_members()         to authenticated;
grant execute on function public.staff_set_level(uuid, text)  to authenticated;
grant execute on function public.staff_kick(uuid)             to authenticated;
grant execute on function public.team_points_summary()        to authenticated;
grant execute on function public.team_ratings()               to authenticated;
grant execute on function public.team_official_ratings()      to authenticated;
grant execute on function public.event_tier_weight(text)      to authenticated;
grant execute on function public.team_official_summary()      to authenticated;
grant execute on function public.team_data_counts()           to authenticated;
grant execute on function public.get_shared_scouting(text)    to authenticated;
grant execute on function public.staff_list_share_codes()     to authenticated;
grant execute on function public.validate_data(jsonb, text)   to authenticated;

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
-- =====================================================================


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
  using (public.is_staff());

-- Central write helper. Every writer below (the generic trigger, staff_kick(), the
-- manage-member Edge Function) calls this rather than inserting into audit_log
-- directly, so actor_role is always worked out the same way.
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
begin
  v_row  := to_jsonb(case when TG_OP = 'DELETE' then OLD else NEW end);
  v_id   := coalesce(v_row ->> 'id', v_row ->> 'user_id', v_row ->> 'team_number', '');
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
      format('%s share code "%s"', v_verb, v_row ->> 'label')
    when 'team_info' then
      format('%s team info: team %s', v_verb, v_row ->> 'team_number')
    when 'staff_members' then
      format('%s staff member %s', v_verb,
        coalesce((select email from auth.users where id = (v_row ->> 'user_id')::uuid), v_row ->> 'user_id'))
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
drop trigger if exists audit_staff_members  on public.staff_members;
drop trigger if exists audit_member_grants  on public.member_grants;
create trigger audit_events        after insert or update or delete on public.events          for each row execute function public.audit_row_change();
create trigger audit_scouting      after insert or update or delete on public.scouting_entries for each row execute function public.audit_row_change();
create trigger audit_pit           after insert or update or delete on public.pit_entries      for each row execute function public.audit_row_change();
create trigger audit_fields        after insert or update or delete on public.scout_fields     for each row execute function public.audit_row_change();
create trigger audit_codes         after insert or update or delete on public.share_codes      for each row execute function public.audit_row_change();
create trigger audit_team_info     after insert or update or delete on public.team_info        for each row execute function public.audit_row_change();
create trigger audit_staff_members after insert or update or delete on public.staff_members     for each row execute function public.audit_row_change();
create trigger audit_member_grants after insert or update or delete on public.member_grants     for each row execute function public.audit_row_change();

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

revoke all on function public.log_action(text, text, text, text, jsonb) from public, anon;
revoke all on function public.staff_search_audit_log(text, text, text, text, timestamptz, timestamptz, int, int) from public, anon;
grant execute on function public.log_action(text, text, text, text, jsonb) to authenticated;
grant execute on function public.staff_search_audit_log(text, text, text, text, timestamptz, timestamptz, int, int) to authenticated;


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
  ('table','team_info'), ('table','audit_log'),
  ('view','official_matches_combined'), ('view','official_team_matches'),
  ('view','official_match_teams'),
  ('function','is_staff'), ('function','is_student'), ('function','my_access_level'),
  ('function','session_live'),
  ('function','staff_list_members'), ('function','staff_set_level'), ('function','staff_kick'),
  ('function','validate_data'), ('function','team_ratings'), ('function','team_points_summary'),
  ('function','team_official_ratings'), ('function','event_tier_weight'), ('function','team_official_summary'),
  ('function','team_data_counts'), ('function','get_shared_scouting'),
  ('function','staff_list_share_codes'), ('function','set_default_event'),
  ('function','log_action'), ('function','staff_search_audit_log'),
  ('bucket','scouting-photos'), ('bucket','team-logos')
)
select e.kind, e.name,
       case e.kind
         when 'function' then exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = e.name)
         when 'bucket'   then exists (select 1 from storage.buckets where id = e.name)
         else to_regclass('public.' || e.name) is not null
       end as present
from expected e
order by present, e.kind, e.name;
