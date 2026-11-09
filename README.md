# 1307Robosaints.github.io

Public website and **1307scout** scouting app for St. Thomas Aquinas Robotics Team 1307
(Dover, NH). Plain static HTML/CSS/JS — no build step required to run it, no bundler, no
framework. Hosted on GitHub Pages at [robosaints1307.com](https://robosaints1307.com) (see `CNAME`).

## Site map

**Public pages** — no account needed:
`index.html`, `about-the-students.html`, `about-the-mentors.html`, `about-the-robot.html`,
`oursponsors.html`, `business-plan.html`, `Gallery/gallery.html`, `contact.html`,
`privacy-policy.html`, `terms-of-service.html`, and `ratings.html`, which explains how team
ratings and the other derived stats are calculated. Update it whenever that math changes.

**1307scout** — the team's scouting app, gated by sign-in (`signin.html`, `account.html`). The 1307scout
menu is kept short, ordered by use: Team Database, Our Matches, Alliance View, Scout, then the two
playoff pages and (staff) the Staff Portal. Every page is on the 1307scout home page; Match Flags and
How Ratings Work are linked only from there (and from the pages that reference them):
- `1307scout.html` — landing/command-center page, links out based on your access level.
- `scout.html` — enter match and pit scouting data for the current event. Anyone else with a
  free account can use a share code here to view a limited slice of data.
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
  `query.html?team=1307` opens a team directly.
- `flags.html` — Match Flags: for one event, every played qualification match whose scouting data
  may be wrong or missing. Entries are checked against the schedule, the official per-robot TOWER
  results, the alliance's official FUEL points, other scouts, the team's usual numbers and the
  vision data. Robots nobody scouted are flagged too, at a lower level when vision covered them. Any
  team member can mark a flag as fine, fixed or needing a rescout (`match_flag_reviews`). The page
  also lists who to scout next, by lowest coverage, and a coverage grid. The rules are on `ratings.html`.
- `matches.html` — Our Matches: every match one team (1307 unless changed) has at an event, read from
  the synced FRC/TBA schedule. Upcoming matches show partners and opponents with grades, scouted
  points and win chance; played ones collapse to a one-line result. Any team member can add a match
  the sync doesn't have or fix a line-up (`match_schedule`), and go back to the official version.
  Each match links to its Match Strategy plan (played matches only when one was saved).
- `alliance.html` — Alliance View: compares up to six teams picked on the Team Database, as a row
  of 3 cards per alliance, all on one screen with no scrolling on a widescreen display (phones and
  tablets stack the cards). Picks are kept in that browser (`js/alliance.js`), so each person and
  device has their own. A link can also set both alliances: `alliance.html?red=1,2,3&blue=4,5,6`,
  which is how every match listing opens a match here. To change which stats are compared, edit
  `STAT_GROUPS` in the page.
  Each alliance also gets a grade and an estimated win chance, explained on `ratings.html`.
- `strategy.html` — Match Strategy: a field map with each match's teams in their driver stations
  (from the synced schedule, with Our Matches edits, or typed in by hand). Drag robots to their
  starting spots and turn them, then draw on the field with a pen or arrows in six colors. The
  eraser removes the lines it touches; Clear removes all drawing, one color, just arrows or
  freehand lines, or puts the robots back. Flip turns the map to read from either end. Each plan
  is saved with its match (`match_strategies`) for the whole team as it's drawn; other screens
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
  numbers. To change the table's stats, edit `COLUMNS` in the page.
- `bracket.html` — Playoff Bracket: the 2026 FRC 8-alliance double-elimination bracket for an event.
  Round 1 fills from the Playoff Selection alliances, and official results move alliances along, so
  it only advances once an event syncs. With fewer than 8 alliances, an empty alliance is a bye: the
  alliance it would have played moves on without playing. When official scores are tied, staff click who won the
  tiebreaker. On a 4-team alliance staff click who sits out each match (the 3rd pick by default).
  The match layout is `MATCHES` in the page.
- `portal.html` — staff-only admin: events, scouting form fields, share codes, test-team tags,
  team names/logos, member access levels, and an audit log of who changed what and when (staff,
  mentor/student, guest, or system actions are tagged separately, with a searchable/filterable list;
  entries are deleted automatically after 6 months). Routine official-sync updates aren't logged.
  The clock button on an event row turns on competition-day auto-sync for that event.

Access levels (`staff`, `mentor`, `student`, `guest`) are enforced server-side with Postgres
row-level security, not just by hiding nav links — see `SQL/rebuild_all.sql`.

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
`team-logos` bucket under `tba/`). A name or logo staff set on the Team Info tab wins over it. Deploy it once with
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

**Vision worker** (`vision/`): a Python program that runs on a team laptop with a GPU, not on the
website. It reads match video from the links on The Blue Alliance. It reads the scoreboard overlay
for a score timeline, and tracks robots by their bumpers with a YOLO model the team trains. It saves
per-robot estimates to `vision_matches` and `vision_robots` with the service role key. Setup, event
calibration, model training and the meaning of every number are in `vision/README.md`. Without a
trained model it still reads the scoreboard.

## Contact form

The contact form (`contact.html`) sends mail client-side via [EmailJS](https://www.emailjs.com/) —
no server component. Topics and who each one emails are configured in `js/contact-config.js`
(the only file you should need to edit to add/remove a topic or change who gets notified).

## Local development

There's no build step — open any `.html` file directly, or serve the folder with any static file
server. `gulpfile.js`/`package.json` are leftover from the original Bootstrap template this site
started from (see below) and aren't required to run or edit the site.

## Credit

Originally built from a Bootstrap template — go check it out! It's a mix of the gallery template
and the modern business template, with plenty reformatted to fit our needs.

Site and 1307scout maintained by Daniel Lowry. Questions or bug reports: see the "website
support" / "1307scout support" topics on the [Contact page](https://robosaints1307.com/contact.html).
