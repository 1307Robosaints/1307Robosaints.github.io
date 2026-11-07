# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Public website and **1307scout** scouting app for FRC Team 1307 (St. Thomas Aquinas Robotics,
Dover NH), hosted on GitHub Pages at robosaints1307.com. Plain static HTML/CSS/JS — no build
step, no bundler, no framework, no `npm install` needed to work on it. `package.json`/
`gulpfile.js` are leftovers from the original Bootstrap template and are not part of the
workflow (see README "Local development" / "Credit").

Read `README.md` first — it has the site map (public pages vs. 1307scout) and the backend
overview. This file adds the architecture detail the README doesn't go into.

## Running it locally

Open any `.html` file directly, or serve the repo root with any static file server. There is
no build/lint/test tooling in this repo — don't introduce one unless asked.

## Architecture

### No bundler, inline-script pages

Shared JS lives only in `js/` (`auth-config.js`, `auth.js`, `contact-config.js`,
`contact_me.js`, plus the vendored `jqBootstrapValidation.js`). Everything specific to a page
(`scout.html`, `query.html`, `portal.html`, `account.html`, `1307scout.html`) is written as a
large inline `<script>` block at the bottom of that HTML file — there's no per-page `.js` file
to go hunting for. When asked to change scouting-app behavior, go straight into the relevant
`.html` file's inline script.

Every page loads, in order: jQuery, Bootstrap, the Supabase JS CDN bundle
(`@supabase/supabase-js` UMD), then `/js/auth-config.js`, then `/js/auth.js`. `auth.js` builds
`window.RS = { sb: <supabase client> }` — every page's inline script calls Supabase through
`RS.sb` (aliased locally as `sb`), e.g. `sb.from("scouting_entries").select(...)`,
`sb.rpc("my_access_level")`, `sb.storage.from("scouting-photos").upload(...)`. CDN `<script>`
tags carry `integrity` hashes, so bumping a library version means updating its hash on every page. `auth.js` also
drives the shared nav: it hides/shows `[data-role="staff"]` / `[data-role="team"]` elements and
highlights the active nav link — this is cosmetic only, not the real access control.

### Backend: Supabase, and the DB is the source of truth for access control

Backend is Supabase (Postgres + Auth + Storage). Real access control is enforced in Postgres via
row-level security policies and `security definer` functions (`is_staff()`, `is_student()`,
`my_access_level()`), **not** by what the frontend hides. Hiding a nav link or disabling a
button in HTML/JS is UX polish; it is never sufficient on its own to gate a feature — any new
gated feature needs an RLS policy or a function check in the SQL, mirroring the pattern already
in `SQL/rebuild_all.sql`.

Access levels: `staff`, `mentor`/`student` (team), `guest`. `staff_members` is an allowlist
editable from the SQL Editor or by existing staff through `staff_set_level()`; `member_grants` covers mentors/students on personal emails and
explicit guest grants; students otherwise qualify via a `@stalux.org` login.

### `SQL/rebuild_all.sql` is the single source of truth for the schema

One file, organized in numbered sections (0 through 16, see the header comment for the full
list), written to be safe to re-run end-to-end in the Supabase SQL editor against either a fresh
project or an existing one (tables are `create if not exists`, functions `create or replace`,
policies dropped and recreated). When changing the data model, edit this file directly rather
than writing a new migration file — the other files in `SQL/` (`import_*.sql`,
`link_battle_of_the_bay.sql`) are one-off **data** imports (new events, FRC/TBA event-code
links), kept only as a record; `rebuild_all.sql` doesn't depend on them and re-running it does
not re-run them.

Key tables/functions to know when touching 1307scout:
- `events`, `scouting_entries` (match scouting), `pit_entries` (one per team per event, owned by
  the team, not per-scout) — pit data is validated against `scout_fields` via
  `validate_data()`/`validate_pit_entry()` triggers.
- `scout_fields` — staff-defined form fields (scope `match` or `pit`); `field_type` includes
  `'image'`, which drives a file/camera picker on the Scout page that uploads to the
  `scouting-photos` Storage bucket and stores the resulting public URL as the field's string
  value.
- `purge_member_data()` — removes what a banned or deleted account entered; `service_role`
  only, called by `manage-member` and `delete-account`, which then remove the photo files it
  returns through the Storage API.
- `share_codes` — revocable, optionally-expiring codes that give a signed-in guest a slice of
  data (read via the `get_shared_scouting()` RPC). Wrong guesses are throttled per account
  through `share_code_attempts`.
- `official_matches` / the per-team views in section 8 — official FRC Events + The Blue Alliance
  results, written only by the `official-sync` Edge Function (service role); staff/students can
  read, nobody writes through the normal API. `match_key` format: `qm12` (qualification 12),
  `sf8m1` (playoff set 8 match 1), `f1m2` (finals match 2).
- Team ratings: there are **two independent ratings** kept deliberately separate — one derived
  from human scouting data, one from synced official results (`team_official_ratings()`,
  weighted per-match by the event's `event_tier` via `event_tier_weight()` — districts/
  championships count more than a regular qualifier, off-season counts a little less). See the
  comment on `team_ratings()`/section 9 in `rebuild_all.sql` for the reasoning before changing
  either rating.
- `official-sync` is a separate Supabase Edge Function (not in this repo) that needs its own
  deploy and secrets (`FRC_API_USER`, `FRC_API_TOKEN`, `TBA_API_KEY`, `SYNC_SECRET`) — see
  section 15 of `rebuild_all.sql` for the deploy command and optional `pg_cron` polling setup.
  `manage-member` is a separate Edge Function used by the Staff Portal for member management.
  Its deployed slug is `bright-responder`, so that is the name `portal.html` invokes.
  `delete-account` is a separate Edge Function behind the My Account delete button. Both must
  have "Verify JWT with legacy secret" off: user tokens are signed with the project's ES256
  key, so each function checks the login itself.

## Documentation and comments

When the website or service changes, update the docs that describe it, not just the code —
this includes `README.md`, but also user-facing pages like the privacy policy, terms of
service, and the `1307scout.html` homepage/about content, plus any other page that documents
behavior rather than implements it.

Code should be commented for easy reading, but keep comments short. Paragraph-length comments
are only appropriate as section headers or to describe a major code block, not inline on
individual lines.

### Contact form

`contact.html`'s form sends mail client-side via EmailJS, no server component.
**`js/contact-config.js` is the
only file to edit** to add/remove a topic or change who gets notified for it; it drives
`js/contact_me.js`, which builds the checkboxes, validates input, and sends through EmailJS.
Every topic's recipients always also get `CONTACT_CONFIG.always`, and someone checking multiple
topics still gets exactly one combined email.
