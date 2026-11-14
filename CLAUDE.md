# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Public website and **1307scout** scouting app for FRC Team 1307 (St. Thomas Aquinas Robotics,
Dover NH), hosted on GitHub Pages as three sites from this repo: robosaints1307.com
(informational) and scout.robosaints1307.com (1307scout) from the `stable` branch, and
beta.robosaints1307.com (experimental: the whole site, every page) from `master`. Plain static HTML/CSS/JS — no build
step, no bundler, no framework, no `npm install` needed to work on it. Don't add a `package.json`/lockfile back: the
template's old ones were removed because their dev dependencies set off Dependabot alerts.

Read `README.md` first — it has the site map (public pages vs. 1307scout) and the backend
overview. This file adds the architecture detail the README doesn't go into.

## Running it locally

Open any `.html` file directly, or serve the repo root with any static file server. There is
no build/lint/test tooling for the website — don't introduce one unless asked. The one exception
is `vision/`, a separate Python worker (not served by the site) with its own `requirements.txt` and
`python -m unittest` tests; see `vision/README.md`.

## Branches and releases

Work happens on `master`, which deploys to beta. `stable` only takes releases: see `RELEASING.md`
for the version rules (`VERSION`, `CHANGELOG.md`, `vX.Y.Z` tags), the two-week cadence and event
freeze, and the release/bugfix commands. Don't commit to `stable` unless asked to make a release
or a stable bugfix. `deploy/build.sh` (run by `.github/workflows/deploy.yml`) is the only build: it
splits pages between the info site and stable 1307scout (`PUBLIC` lists the info pages; every
other root page is 1307scout; beta keeps every page), replaces the other site's pages with redirect stubs, rewrites
`href="/page.html"` links across sites, and puts `window.RS_BUILD` in each `<head>`, which `auth.js`
uses for the footer version and the experimental bar. Keep links root-relative (`/page.html`) so that
rewrite finds them, and add a new public page to `PUBLIC`.

**Beta and stable share the Supabase project.** Any change to `rebuild_all.sql` or an Edge Function
reaches the current stable release as soon as it's run or deployed, so it must be additive/
backward compatible with it (add, don't rename or drop; remove the old thing in a later release).

## Architecture

### No bundler, inline-script pages

Shared JS lives only in `js/` (`alliance.js`, `auth-config.js`, `auth.js`, `theme.js`, `contact-config.js`,
`contact_me.js`, `teams.js`, `ratings.js`, `opr.js`, `vision.js`, `visioncheck.js`, `schedule.js`, `alerts.js`,
`resync.js`, `offline.js`, `history.js`, plus the vendored `jqBootstrapValidation.js`).
`schedule.js` is an event's merged schedule (official matches with the `match_schedule` edits laid over
them, in play order) and the match-key helpers; `visioncheck.js` is the vision-vs-scouts comparison
that Match Flags shows and the Scout page uses to decide what to pre-fill (documented on
`ratings.html#vision-prefill`); `alerts.js` turns match alerts on and off for a browser.
`offline.js` makes the "Download for offline" files (a team, the Alliance View, a simplified playoff
pick board); the pick board's script is serialized into the file, so it can't use anything outside itself.
`ratings.js` also has `pagedRows()` (one page first, then 4 at a time) and `lists()`, which reads the
per-team lists through one `team_lists()` call; use those rather than paging the rating RPCs directly.
`resync.js` is the "Resync data" button on every page that shows official results; it refreshes only the
default event, through `resync_default_event()`/`resync_status()` (team members, throttled to one request a minute).
`history.js` is static data, not code: 1307's events and matches from The Blue Alliance (2004 on) for
`results.html`, which prefers `public_team_results()` for any event also in the database.
`opr.js` is component OPR per event, for every numeric field in the official breakdown (Team Database,
Playoff Selection). `vision.js` holds the labels for the vision worker's per-robot keys.
`teams.js` handles team names ("1678 Citrus Circuits") and the TBA lookup; `ratings.js` holds the
grade, alliance-grade and win-chance math, and the loader for it, used by `alliance.html`,
`playoffs.html` and `matches.html` (`query.html` still has its own grade code). Everything specific
to a page (`scout.html`, `query.html`, `flags.html`, `alliance.html`, `matches.html`, `playoffs.html`,
`bracket.html`, `strategy.html`, `shifts.html`, `picklist.html`, `pitcrew.html`, `results.html`, `portal.html`,
`account.html`, `1307scout.html`) is written as a
large inline `<script>` block at the bottom of that HTML file — there's no per-page `.js` file
to go hunting for. When asked to change scouting-app behavior, go straight into the relevant
`.html` file's inline script.

Every page loads `/js/theme.js` in its `<head>`, before the stylesheets: dark mode (chosen on My
Account) is `<html data-theme="dark">` plus the token overrides in `css/modern.css` sections 1b and 15.
Page styles must use the color tokens, not hex, to follow the theme: navy *text* is `--heading`
(`--navy` stays a dark plate with white text in both themes), status colors are `--green`/`--red`/
`--amber`/`--purple`/`--grey` with `-bg` pairs. Solid fills with white text (grade chips) keep hex.
A new logo on a transparent background needs a dark copy named in `data-dark-src`.

Every page loads, in order: jQuery, Bootstrap, the Supabase JS CDN bundle
(`@supabase/supabase-js` UMD), then `/js/auth-config.js`, then `/js/auth.js`. `auth.js` builds
`window.RS = { sb: <supabase client> }` — every page's inline script calls Supabase through
`RS.sb` (aliased locally as `sb`), e.g. `sb.from("scouting_entries").select(...)`,
`sb.rpc("my_access_level")`, `sb.storage.from("scouting-photos").upload(...)`. Gated pages get the
level from `RS.accessLevel()`, which returns null after showing a banner if the server can't be
reached, so a bad connection isn't mistaken for guest access. CDN `<script>`
tags and the Font Awesome stylesheet carry `integrity` hashes, so bumping a library version means updating its hash on every page. `auth.js` also
drives the shared nav: it hides/shows `[data-role="staff"]` / `[data-role="team"]` elements and
highlights the active nav link — this is cosmetic only, not the real access control. It also
lists the app pages that need Supabase (for the "couldn't load" banner; add new app pages there)
and stops any page from running inside another site's frame on the live domain.

### The 1307scout app (PWA)

1307scout installs as a Progressive Web App; the app is the website in its own window, so there is
one codebase and feature parity is automatic. Don't fork pages for the app. Every page has the
manifest/`apple-*` tags in its `<head>` and loads `/js/pwa.js` right after `auth.js` (a new page needs
both). `pwa.js` registers `/sw.js`, adds "Get the app" to the 1307scout menu, shows an offline notice
and runs the `data-app-*` install markup used by `app.html`, `1307scout.html` and `account.html`.
`sw.js` is network-first for the site's own files and cache-first for CDN libraries/fonts, and must
never cache Supabase or any other API response (no user data in Cache Storage). Bump its `VERSION`
when `PRECACHE` changes. Offline, `RS.session()` and `RS.accessLevel({ offline: true })` fall back to
the login and level saved on the device; that only picks which page to show, the database still
checks every request. `scout.html` keeps `rs_offline_<uid>` (events + fields) beside the existing
`rs_drafts_<uid>` queue. `app.html` documents what works offline for users: keep it in step.

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
`link_battle_of_the_bay.sql`, `prune_non_ne_teams.sql`, `prune_2027_events.sql`) are one-off
**data** imports and cleanups (new events, FRC/TBA event-code links, removing non-New England
events/teams, removing 2027 events), kept
only as a record; `rebuild_all.sql` doesn't depend on them and re-running it does
not re-run them.

Key tables/functions to know when touching 1307scout:
- `events`, `scouting_entries` (match scouting), `pit_entries` (one per team per event, owned by
  the team, not per-scout) — pit data is validated against `scout_fields` via
  `validate_data()`/`validate_pit_entry()` triggers.
- `scout_fields` — staff-defined form fields (scope `match` or `pit`); `field_type` includes
  `'image'`, which drives a file/camera picker on the Scout page that uploads to the
  `scouting-photos` Storage bucket and stores the resulting public URL as the field's string
  value.
- `playoff_picks` — the alliances on `playoffs.html`, one row per filled spot (slot 1 is the
  captain). Staff write, the team reads, and the page polls it so every screen stays current.
  `bracket.html` reads it too, and works out each result from `official_matches_combined`
  (`sf1`-`sf13` and `f1`), matching alliances on team numbers. All it stores is what the sync
  can't know: `playoff_tiebreaks` (who won a tied match) and `playoff_lineups` (who sits out on a
  4-team alliance). `events.alliance_size` overrides the 3-or-4 rule for an event.
- `match_schedule` — hand edits for `matches.html`, laid over the official schedule by `match_key`.
- `scout_shifts` (8m) — staff-assigned seats (`red1`..`blue3`) for a range of quals; a trigger stops
  overlaps. `team_member_names()` gives the team display names for the account ids a page shows.
- `pick_list` (8n) — staff's ranked pick list per event; Playoff Selection reads it.
- `match_predictions` (8o) — the last win chance Our Matches showed before each match, written only
  through `log_prediction()` (refuses played matches); `prediction_calibration()` scores them.
- `robot_log` (8p) — Pit Crew's checklists, batteries, repairs and notes for our robot.
- `push_subscriptions` / `match_alerts_sent` (8q) — match alerts. `push_subscribe()`/`push_unsubscribe()`
  from the page; `run_match_alerts()` (pg_cron) calls the `match-alerts` Edge Function in this repo,
  which needs VAPID secrets, and `js/auth-config.js` needs the public key as `pushKey`. It uses FRC
  Nexus queuing status (`NEXUS_API_KEY` secret, event's TBA key) when the event runs on Nexus, and
  the synced schedule otherwise. Nexus asks for a link back to frc.nexus wherever its data shows.
- `scouting_entries.prefilled` / `relayed_by` (8r) — fields filled from vision, and who scanned in an
  entry from an offline scout's QR code via `relay_scouting_entry()` (keeps the original scout as
  `scouted_by`, who must pass `is_team_member()`).
- `public_team_results()` (8s) — 1307's played official matches for the public `results.html`; the only
  function granted to `anon`. Keep it limited to public competition results.
- `match_strategies` (section 8k) — one `strategy.html` plan per match (`plan` jsonb: line-up
  override, robot spots, drawn strokes), any team member reads/writes, last save wins. Kept after
  the match for review; the page locks a played match's plan until someone clicks Edit.
- `vision_matches` / `vision_robots` (section 8j) — written only by the vision worker in `vision/`
  (Python, runs on a team laptop with the service role key; see `vision/README.md`). Team reads,
  nobody writes through the API. Estimates only: no rating reads them. The per-robot keys in
  `vision_robots.data` must stay in step across `vision/rsvision/metrics.py`, `js/vision.js` and `ratings.html`.
- `match_flag_reviews` — what a team member decided about a flag on `flags.html` (fine, fixed,
  rescout). The flags themselves are computed in that page's script, not stored; the rules are
  documented on `ratings.html#flags`. `team_number` 0 means a match- or alliance-level flag.
- `team_info` — staff-set `team_name`/`logo_url`, plus `tba_name`/`tba_logo_url` written by the
  `team-names` Edge Function (this one is in the repo, under `supabase/functions/`). Pages read
  `display_name` and `display_logo`, which prefer what staff set.
- `photo_cleanup_queue` — photo files nothing uses any more, queued by triggers on the entry
  tables. SQL can't delete Storage files, so `scout.html` and `portal.html` call
  `photo_cleanup_paths()` and remove them through the Storage API.
- `purge_member_data()` — removes what a banned or deleted account entered; `service_role`
  only, called by `manage-member` and `delete-account`, which then remove the photo files it
  returns through the Storage API.
- `share_codes` — revocable, optionally-expiring codes that give a signed-in guest a slice of
  data (read via the `get_shared_scouting()` RPC). Wrong guesses are throttled per account
  through `share_code_attempts`.
- `official_matches` / the per-team views in section 8 — official FRC Events + The Blue Alliance
  results, written only by the `official-sync` Edge Function (service role); staff/students can
  read, nobody writes through the normal API. The table holds a full season, so look up a
  team's rows with `official_match_teams_for(int[])` (uses the team-array indexes), not by
  filtering the `official_match_teams` view on `team_number` (`official_lineups_for(int[])` does
  the same for line-ups). They're security definer with an explicit access check on purpose:
  under RLS, Postgres won't use an index for non-leakproof operators like `&&`/`@>`, so a
  team filter sent straight to the table or views reads every row. `team_official_ratings()` and
  `team_official_summary()` read a cache (`official_ratings_cache`/`official_summary_cache`)
  that `refresh_official_cache()` rebuilds from the `*_compute()` functions; a pg_cron job runs
  it every 3 minutes and it only does work after official data changed, re-solving OPR only for
  the events in `official_cache_dirty`. A trigger drops match updates that change nothing but
  `updated_at`, since auto-sync re-sends every match: the project is on Nano compute, and the
  writes used to exhaust its disk IO budget badly enough that Google login timed out. Per-team RPCs return more
  than 1000 rows now, so pages read them with `.range()` paging. `match_key` format: `qm12` (qualification 12),
  `sf8m1` (playoff set 8 match 1), `f1m2` (finals match 2).
- Team ratings (explained for users on `ratings.html`, which must change with the math): there are **two independent ratings** kept deliberately separate — one derived
  from human scouting data, one from synced official results (`team_official_ratings()`: the
  team's qualification-match OPR per event, from `official_opr_fill()` into `official_opr_cache`,
  averaged with each event weighted by matches × `event_tier_weight()` — districts/
  championships count more than a regular qualifier, off-season counts a little less; its
  `score` column is that OPR in points per match, null under 3 qual matches). See the
  comment on `team_ratings()`/section 9 in `rebuild_all.sql` for the reasoning before changing
  either rating.
- `official-sync` is a separate Supabase Edge Function (not in this repo) that needs its own
  deploy and secrets (`FRC_API_USER`, `FRC_API_TOKEN`, `TBA_API_KEY`, `SYNC_SECRET`) — see
  section 15 of `rebuild_all.sql` for the deploy command and optional `pg_cron` polling setup.
  Competition-day auto-sync is `events.auto_sync` (one event at a time, set through
  `set_auto_sync_event()`) plus a `pg_cron` job calling `run_auto_sync()` every 2 minutes. It turns
  itself off 12 hours after it was turned on (`events.auto_sync_since`) or 4 days after the event. It and the
  Resync data button both send their request through `official_sync_request()`.
  `rebuild_all.sql` schedules that job; `auto_sync_health()` reports whether it's really working,
  and the Staff Portal shows that next to the auto-sync status.
  `official-alliances` (in this repo, `supabase/functions/`) is sent alongside every sync request:
  it reads the event's alliances from FRC Events (TBA as fallback) and writes them into
  `playoff_picks` (`source = 'official'`) through `official_set_alliances()`, so the bracket follows them.
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
