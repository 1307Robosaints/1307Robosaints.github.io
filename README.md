# 1307Robosaints.github.io

Public website and **1307scout** scouting app for St. Thomas Aquinas Robotics Team 1307
(Dover, NH). Plain static HTML/CSS/JS — no build step required to run it, no bundler, no
framework. Hosted on GitHub Pages as three sites built from this one repo: the informational site at
[robosaints1307.com](https://robosaints1307.com), 1307scout at
[scout.robosaints1307.com](https://scout.robosaints1307.com) (stable releases, `stable` branch), and
an experimental copy of the whole site at [beta.robosaints1307.com](https://beta.robosaints1307.com) (`master`).
See [Branches and releases](#branches-and-releases).

## Site map

**Public pages** — no account needed. All but `ratings.html` are served from robosaints1307.com;
everything else is on the 1307scout sites (`PUBLIC` in `deploy/build.sh` decides):
`index.html`, `about-the-students.html`, `about-the-mentors.html`, `about-the-robot.html`,
`oursponsors.html`, `business-plan.html`, `Gallery/gallery.html`, `contact.html`,
`privacy-policy.html`, `terms-of-service.html`, `ratings.html`, which explains how team
ratings and the other derived stats are calculated (update it whenever that math changes), and
`results.html`, Season Results: every event 1307 has played since 2004, by season, with records,
ranks, playoff finishes, awards and every match, under a highlight reel of the team's event wins.
Past seasons come from `js/history.js`, a one-time copy of The Blue Alliance's record (2004 to 2026);
live seasons come from `public_team_results()`, the one function anyone can call without signing in,
and win over the copy for any event in both. It's in the About Us menu.

**1307scout** — the scouting app, gated by sign-in (`signin.html`, `account.html`). It has two halves,
and the 1307scout menu and home page are split the same way:
- **Data**, shared by every team: Team Database, Alliance View, Scout, Match Flags, Playoff Selection
  and Playoff Bracket. Scouting entries, pit data, official results, flag reviews and playoff
  alliances belong to nobody in particular.
- **My Team**, your own team's: Our Matches, Match Strategy, Pit Crew, Pick List, Scout Shifts and
  Team Management. Strategy plans, the robot log, the pick list and scout shifts carry an
  `owner_team`, and only that team's members can see them.

Each account is on at most one FRC team, as a **manager** or a **member** (SQL section 3b). Every
account says which team it's on, or that it isn't on one: the sign-up form requires it, and every
1307scout page asks an account that hasn't answered (`js/auth.js`; the site owner's account is never
asked). A claim is verified at once by an email domain the team listed (1307: `stalux.org`), an email
invitation from its managers, a join code or invite link, or access staff had already given that
account. Otherwise the account is in quarantine: a guest, with its status shown on the home page, My
Account and Team Management, until one of the team's managers or site staff verifies it. A team's first
manager is approved by site staff (Teams tab). Site staff can act as any team, as its manager, to see
every page and change any setting. Quarantine is on (`app_settings.require_team_claims`, a switch in
the Teams tab): quarantined accounts have exactly a guest's access. The one exception is for the stable
release, which has no team prompt: an `@stalux.org` account that hasn't answered the prompt yet is
still on team 1307 as a member, since that domain verifies it anyway. How Ratings Work is linked from the home page. For team members the home page also shows their team's next match at the default event:
- `1307scout.html` — landing/command-center page, links out based on your access level.
- `app.html` — Get the app: how to install 1307scout as an app on each kind of device, and what
  works offline. Linked as "Get the app" in the 1307scout menu, and from the home page and My Account.
- `scout.html` — enter match and pit scouting data for the current event. Anyone else with a
  free account can use a share code here to view a limited slice of data. A scout with a shift sees
  their next seat and team, and **Fill in** starts that entry (`?team=&match=` links do the same).
  Once vision has proven itself against this event's scouts, a new entry starts with vision's answer
  for "left starting zone" (marked for the scout to check, and recorded in the entry's `prefilled`)
  and shows vision's FUEL estimate as a hint (`js/visioncheck.js`). Offline, **Hand off by QR** shows
  each new draft as a QR code, and a scout who is online saves it with **Scan a scout's QR**, through
  `relay_scouting_entry()`: it stays the first scout's entry, with its own id, so it can't be saved twice.
- `shifts.html` — Scout Shifts: a team's managers give its members a driver-station seat for a range of
  qualification matches (`scout_shifts`), one at a time or as a rotation over the people ticked.
  Everyone sees the seat grid, with seats nobody has, and played seats nobody entered.
- `query.html` — Team Database: every team's scouted and official match history, pit/robot
  parameters, full stats for every form field, the official score breakdown, match line-ups, pit
  history, insights (win %, margins, recent form, per-event results, scoring averages, and a
  rating breakdown), each event's OPR estimate for every official score field (`js/opr.js`), the
  vision worker's estimates when it has run, and two independent ratings (one from human scouting, one from synced official
  results — see the comment on `team_ratings()` in `SQL/rebuild_all.sql` for why they're kept separate).
  A team's card shows its name and logo, and buttons to add it to the red or blue alliance. Every
  match row links to that match in the Alliance View, and every event is tagged with its level
  (Qualifier, District Champs, Worlds, Off-season) from the tier set in the Staff Portal.
  Picking an event narrows the list to its teams and shows that event's qualification rankings,
  worked out from the synced official matches (`?event=<id>` links straight to them).
  The card also has trend charts (scouted points and official score per match, OPR per event), a
  searchable list of every scouted note and other text answer, and **Export CSV** for the team's
  scouted matches, pit entries and official results; an event's rankings can export all its scouting.
  Exports leave out who scouted each entry.
  `query.html?team=1307` opens a team directly. **Download for offline** saves the open team as one
  .html file (`js/offline.js`) that opens with no connection: the page's styles and the photos and
  logos are copied in, the buttons are left out, and it says when it was saved. It doesn't update.
- `flags.html` — Match Flags: for one event, every played qualification match whose scouting data
  may be wrong or missing. Entries are checked against the schedule, the official per-robot TOWER
  results, the alliance's official FUEL points, other scouts, the team's usual numbers and the
  vision data. Robots nobody scouted are flagged too, at a lower level when vision covered them. Any
  team member can mark a flag as fine, fixed or needing a rescout (`match_flag_reviews`). The page
  also lists who to scout next, by lowest coverage, and a coverage grid. Vision vs scouts shows how
  often vision agrees with this event's scouts, field by field, which decides what the Scout page
  pre-fills. Staff also see Scout accuracy: each scout's TOWER answers against official results,
  FUEL gaps to other scouts and to vision, wrong-match entries, and missed shift seats. The rules are
  on `ratings.html`.
- `matches.html` — Our Matches: every match one team (1307 unless changed) has at an event, read from
  the synced FRC/TBA schedule. Upcoming matches show partners and opponents with grades, scouted
  points and win chance; played ones collapse to a one-line result. Any team member can add a match
  the sync doesn't have or fix a line-up (`match_schedule`), and go back to the official version.
  Each match links to its Match Strategy plan (played matches only when one was saved). The win
  chance shown for an upcoming match is saved (`log_prediction()`) until it's played, and
  `ratings.html#win-chance-check` shows how those predictions held up (`prediction_calibration()`).
- `alliance.html` — Alliance View: compares up to six teams picked on the Team Database, as a row
  of 3 cards per alliance, all on one screen with no scrolling on a widescreen display (phones and
  tablets stack the cards). Picks are kept in that browser (`js/alliance.js`), so each person and
  device has their own. A link can also set both alliances: `alliance.html?red=1,2,3&blue=4,5,6`,
  which is how every match listing opens a match here. To change which stats are compared, edit
  `STAT_GROUPS` in the page.
  Each alliance also gets a grade and an estimated win chance, explained on `ratings.html`.
  **Download for offline** saves both alliances as a standalone .html file, the same way as a team.
- `strategy.html` — Match Strategy: a field map with each match's teams in their driver stations
  (from the synced schedule, with Our Matches edits, or typed in by hand). Drag robots to their
  starting spots and turn them, then draw on the field with a pen or arrows in six colors. The
  eraser removes the lines it touches; Clear removes all drawing, one color, just arrows or
  freehand lines, or puts the robots back. Flip turns the map to read from either end. Each plan
  is saved as it's drawn. For a match your team plays in, there's one plan per alliance
  (`alliance_strategies`), shared by the three teams on it and hidden from the other alliance; who
  is on an alliance comes from the official line-up. A match your team isn't in gets a plan only your
  team sees (`match_strategies`). Other screens
  showing it pick up changes within 15 seconds, and the last save wins. Once the match is played,
  the plan locks and shows the result beside it, for reviewing what worked (Edit unlocks it), and
  the match list can be narrowed to matches with a plan. Plans for a custom line-up aren't a real
  match, so they stay in that browser. `strategy.html?event=<id>&match=qm12` opens one plan, which
  is how Our Matches links to it. Plans download as a picture. The map draws the 2026 REBUILT
  field to scale: HUBs, BUMPs, TRENCHes, TOWERs, DEPOTs, OUTPOSTs, the robot starting lines and the
  starting FUEL, from the `GAME` block in the page (replace it for a new season). Robots start
  behind their starting line. The Field menu can hide the structures (a plain grid), or use a
  field picture instead, which can also be set for everyone with `FIELD_IMAGE`.
- `playoffs.html` — Playoff Selection: staff enter an event's alliances as they form, and the whole
  team sees them update. Once FRC Events (or TBA) publishes the alliances, every sync replaces them
  with the official ones (the `official-alliances` Edge Function), and the board says so. Beside
  them, every team at the event that hasn't been picked is ranked in a sortable table, official data
  first: the official rating (the default sort), then the scouting rating, official results, scouted
  stats, and pit data. Each alliance has Red and Blue buttons that open it in
  the Alliance View. Alliances have 3 teams, or 4 at district championships and the FIRST
  Championship; staff can switch any event with the 4-team toggle. The table includes each team's
  OPR for the event, its estimated AUTO and teleop FUEL there (component OPR), and its official
  AUTO and endgame climb rates from FRC's per-robot TOWER data, so a team nobody scouted still has
  numbers. To change the table's stats, edit `COLUMNS` in the page. The first column is the team's
  place on our Pick List, and the board names the best team on it still available.
- `picklist.html` — Pick List: your team's ranked list for alliance selection (`pick_list`), built before
  it starts. Drag or use the arrows to reorder, give each team a tier (first pick, second pick, maybe,
  do not pick) and a note. Teams already picked are greyed as Playoff Selection fills. Each row shows
  the team's grades, OPR, scouted points and its scouted notes from the event.
- `pitcrew.html` — Pit Crew: your team's robot at an event (`robot_log`). A pre-match checklist per
  match (the items and the low-battery voltage are the team's settings, set on Team Management; the
  defaults are in `js/team.js`), batteries with voltage and which match they went into, repairs and
  notes. The top line says whether the next match has its checklist and battery.
  **Download for offline** saves a simplified pick board for the event as one .html file: the
  alliances as they stand, and every team's stats for both All season and This event, worked out at
  download time. Offline, anyone can fill spots in draft order (Pick, or type a number), remove
  teams, sort and switch scope. Those picks stay in that browser and never reach the team's data.
- `bracket.html` — Playoff Bracket: the 2026 FRC 8-alliance double-elimination bracket for an event.
  Round 1 fills from the Playoff Selection alliances, and official results move alliances along, so
  it only advances once an event syncs. With fewer than 8 alliances, an empty alliance is a bye: the
  alliance it would have played moves on without playing. When official scores are tied, staff click who won the
  tiebreaker. On a 4-team alliance staff click who sits out each match (the 3rd pick by default).
  The match layout is `MATCHES` in the page.
- `team.html` — Team Management: for someone on no team, where their claim stands, invitations to
  accept, which team they're on, a join code (`team.html?join=CODE` is an invite link), and asking
  site staff to manage a team. For a member, the team's roster and managers. For a manager: verify or
  turn down people waiting, invite by email, make members managers or take them off the team, make and
  revoke join codes and invite links, list the email domains that verify members at once, choose whether members or only managers can
  change Match Strategy, Pit Crew, Pick List and Scout Shifts (`teams.settings.permissions`), and
  set the Pit Crew checklist and low-battery voltage (`teams.settings.pit`). Site staff search for a team
  by number or name to act as it. A team keeps at least
  one manager.
- `portal.html` — staff-only admin: events, scouting form fields, share codes, test-team tags,
  team names/logos, teams (everyone waiting to be verified on any team, requests to manage a team,
  the quarantine switch, act as a team, take a disputed manager off a team), member access levels, and an audit log of who changed what and when (staff,
  mentor/student, guest, or system actions are tagged separately, with a searchable/filterable list;
  entries are deleted automatically after 6 months). Routine official-sync updates aren't logged.
  The clock button on an event row turns on competition-day auto-sync for that event.

**Tables** — on the Staff Portal (Teams, Members), Team Management, Pit Crew, Match Flags and the Team
Database's team card, clicking a column header sorts the table by it (again to reverse; the lit arrow shows
which), and a search box filters rows by any text in them, such as a name, email or team number
(`js/tables.js`). The Staff Portal's Teams tab can also narrow to the teams at one event, and Members to one
access level.

**Dark mode** — chosen on My Account (Light, Dark, or Match device). `js/theme.js` loads in every
page's `<head>`, before the stylesheets, and sets `<html data-theme>`; `css/modern.css` redefines its
color tokens under `[data-theme="dark"]` (section 1b) and fixes up Bootstrap's own colors (section 15).
Page styles should use the tokens (`--ink`, `--heading`, `--white`, `--line`, `--green`/`--red`/`--amber`
and their `-bg` pairs, ...) rather than hex colors, or they won't follow the theme. `--navy` stays a dark
plate in both themes; navy *text* is `--heading`. The choice is kept on the device (`rs_theme`) and in
the account's `user_metadata.theme`, which `js/auth.js` applies on other devices. Images with a
dark-theme copy name it in `data-dark-src` (`img/robosaintslogo-dark.png`,
`img/Sponsorphotos/staluxlogo-dark.png`).

Access levels (`staff`, `mentor`, `student`, `guest`) and team roles (`manager`, `member`) are
enforced server-side with Postgres row-level security, not just by hiding nav links — see
`SQL/rebuild_all.sql`. Site staff run the site; they get no special access to another team's own data.
GitHub Pages can't send security headers, so `js/auth.js` also refuses to run any page inside
another site's frame (on robosaints1307.com only, so local previews still work).

## Backend

1307scout runs on [Supabase](https://supabase.com) (Postgres + Auth + Storage), configured in
`js/auth-config.js` (the anon key in there is meant to be public — real access control lives in
the database's row-level security policies, not the key).

**`SQL/rebuild_all.sql`** is the single source of truth for the database schema: every table,
policy, and function, written to be safe to re-run end-to-end in the Supabase SQL editor. Run it
whole after cloning a fresh Supabase project, and again any time this file changes.

The other files in `SQL/` are one-off **data** imports (new events, linking an event to its
FRC/TBA code, etc.) — row-only changes that don't touch the schema. They're kept for a record of
what was imported and when; re-running `rebuild_all.sql` doesn't depend on them.

**Team names and logos** fill in on their own: when a page shows a team that hasn't been looked up
in 30 days, `js/teams.js` asks the `team-names` Edge Function (`supabase/functions/team-names/`) to
look it up on The Blue Alliance. It saves the nickname and the team's FIRST avatar (stored in the
`team-logos` bucket under `tba/`). A name or logo staff set on the Staff Portal's Team Info tab wins over it;
that tab lists the test teams and teams TBA has no name for, which are the ones that need it. Deploy it once with
`supabase functions deploy team-names --no-verify-jwt`; it uses the `TBA_API_KEY` secret that
official-sync already has.

Robot photos uploaded from the Scout page land in a public Supabase Storage bucket
(`scouting-photos`), created by `rebuild_all.sql`. Deleting an entry or replacing its photo
queues the file, and the Scout page and Staff Portal remove it through the Storage API.

**Competition-day auto-sync** refreshes one staff-chosen event from FRC/TBA every 2 minutes
(9:30, 9:32, 9:34...). It runs on the server through `pg_cron`, so nobody has to keep
a page open, and turns itself off 12 hours after staff turn it on (click the clock again each
competition morning) or 4 days after the event date, whichever comes first. `SQL/rebuild_all.sql` enables pg_cron
and pg_net and schedules the job. The one manual step is storing `sync_secret` in the Vault (section 15).
The check query at the end of that file shows if either is missing, and the Staff Portal warns if a
run is failing, the job has stopped, or it's still on an old schedule.

**Resync data** is a button on every page that shows official results (Our Matches, Match Flags,
Playoff Selection, Bracket, Team Database, Alliance View). Any team member can press it. It
refreshes only the default event (the starred one in the Staff Portal), through
`resync_default_event()`, which sends the same server-side request auto-sync does, so it works
for students who can't call `official-sync` directly. Presses within 60 seconds of each other share
one request. The button is `js/resync.js`.

**Match alerts**: team members can turn on a push notification per device on My Account
(`js/alerts.js`), for shortly before a team needs to queue. At events that run queuing on
[FRC Nexus](https://frc.nexus), the function reads Nexus's live status (needs the `NEXUS_API_KEY`
secret, and the event's TBA key, which Nexus also uses) and alerts when the match is queuing or 10
minutes before its estimated queue time. Elsewhere it falls back to the synced schedule: 3 or fewer
matches after the last one with a score, which runs a few minutes behind the field. While auto-sync is on,
the `match-alerts` pg_cron job calls `run_match_alerts()`, which asks the `match-alerts` Edge Function
(`supabase/functions/match-alerts/`) to send them through Web Push. Setup: generate VAPID keys, set
them as that function's secrets (plus `NEXUS_API_KEY` for Nexus), deploy it with `--no-verify-jwt`, and put the public key in
`js/auth-config.js` as `pushKey` (blank keeps the switch off). See the top of its `index.ts`.

**Vision worker** (`vision/`): a Python program that runs on a team laptop with a GPU, not on the
website. It reads match video from the links on The Blue Alliance. It reads the scoreboard overlay
for a score timeline, and tracks robots by their bumpers with a YOLO model the team trains. It saves
per-robot estimates to `vision_matches` and `vision_robots` with the service role key. Setup, event
calibration, model training and the meaning of every number are in `vision/README.md`. Without a
trained model it still reads the scoreboard.

## The 1307scout app (PWA)

1307scout installs as a Progressive Web App on phones, tablets, Chromebooks and computers, from the
site itself (no app store). The app *is* the website in its own window, so the two always have the
same features: there's no second codebase to keep in step. Install steps for users are on `app.html`.

- `manifest.webmanifest` — the app's name, icons (`img/app/`), colors and home-screen shortcuts.
  Every page links it in its `<head>`, along with the iOS `apple-*` tags.
- `js/pwa.js` — on every page, after `auth.js`. Registers the service worker, adds "Get the app" to
  the 1307scout menu, shows an offline notice, and runs the install markup: `[data-app-install]`
  buttons, `[data-app-when="installed"|"browser"]` and `[data-app-device]` (see the top of the file).
- `sw.js` — the service worker. The site's own files are network-first (an online visit always gets
  the latest version, the saved copy only when the network fails or stalls for 4 s); the CDN
  libraries and fonts are cache-first. It never touches Supabase or any other API, so no scouting
  data is cached and access control is unchanged. `offline.html` is shown for a page that isn't
  saved yet. Bump `VERSION` in `sw.js` when its `PRECACHE` list changes.
- Offline Scout: `RS.session()` and `RS.accessLevel({ offline: true })` in `js/auth.js` fall back to
  the login and access level saved on the device, and `scout.html` keeps a copy of the events and
  form fields (`rs_offline_<user id>`), so the page opens with no connection and match entries go to
  the existing draft queue, and the scout's shifts for the event are kept the same way. Pit entries
  and photos still need a connection. Signing out clears the saved level and copies, not unsent drafts.
- `sw.js` also shows match alerts (its `push` and `notificationclick` handlers).

A store version later would wrap these same files (Capacitor for iOS/Android) rather than fork them.

## Contact form

The contact form (`contact.html`) sends mail client-side via [EmailJS](https://www.emailjs.com/) —
no server component. Topics and who each one emails are configured in `js/contact-config.js`
(the only file you should need to edit to add/remove a topic or change who gets notified).

## Branches and releases

`master` is experimental: every push deploys to beta.robosaints1307.com, so new work gets tried out
there. `stable` gets proven work as numbered releases (`VERSION`, `CHANGELOG.md`, tags `vX.Y.Z`:
MAJOR for major content, MINOR for features, PATCH for fixes), every two weeks, with only PATCH
releases from a week before an event until it ends. Pushing `stable` deploys robosaints1307.com and
scout.robosaints1307.com. `.github/workflows/deploy.yml` runs `deploy/build.sh`, which makes each site
from the same files (redirect stubs for pages that live on the other site, cross-site links,
`version.json`). Both sites share one Supabase project, so SQL and Edge Function changes have to keep
the current stable release working. Release steps and the one-time setup: `RELEASING.md`.

## Local development

There's no build step — open any `.html` file directly, or serve the folder with any static file
server. The service worker registers on `localhost` too; since it's network-first, edits still
show on reload, but use DevTools → Application → Service workers → "Update on reload" when changing
`sw.js` itself. There's no `package.json`: the original Bootstrap template's npm/gulp files were
removed, since nothing used them and their old dev dependencies set off Dependabot alerts.

## Credit

Originally built from a Bootstrap template — go check it out! It's a mix of the gallery template
and the modern business template, with plenty reformatted to fit our needs.

Site and 1307scout maintained by Daniel Lowry. Questions or bug reports: see the "website
support" / "1307scout support" topics on the [Contact page](https://robosaints1307.com/contact.html).
