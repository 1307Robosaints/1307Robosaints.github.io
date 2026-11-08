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

**1307scout** — the team's scouting app, gated by sign-in (`signin.html`, `account.html`). Every page
is in the 1307scout menu and on the home page, grouped as Scouting, Competition day, and Help/admin:
- `1307scout.html` — landing/command-center page, links out based on your access level.
- `scout.html` — enter match and pit scouting data for the current event. Anyone else with a
  free account can use a share code here to view a limited slice of data.
- `query.html` — Team Database: every team's scouted and official match history, pit/robot
  parameters, full stats for every form field, the official score breakdown, match line-ups, pit
  history, insights (win %, margins, recent form, per-event results, scoring averages, and a
  rating breakdown), and two independent ratings (one from human scouting, one from synced official
  results — see the comment on `team_ratings()` in `SQL/rebuild_all.sql` for why they're kept separate).
  A team's card shows its name and logo, and buttons to add it to the red or blue alliance. Every
  match row links to that match in the Alliance View, and every event is tagged with its level
  (Qualifier, District Champs, Worlds, Off-season) from the tier set in the Staff Portal.
- `matches.html` — Our Matches: every match one team (1307 unless changed) has at an event, read from
  the synced FRC/TBA schedule. Upcoming matches show partners and opponents with grades, scouted
  points and win chance; played ones collapse to a one-line result. Any team member can add a match
  the sync doesn't have or fix a line-up (`match_schedule`), and go back to the official version.
- `alliance.html` — Alliance View: compares up to six teams picked on the Team Database, as a row
  of 3 cards per alliance, all on one screen with no scrolling on a widescreen display (phones and
  tablets stack the cards). Picks are kept in that browser (`js/alliance.js`), so each person and
  device has their own. A link can also set both alliances: `alliance.html?red=1,2,3&blue=4,5,6`,
  which is how every match listing opens a match here. To change which stats are compared, edit
  `STAT_GROUPS` in the page.
  Each alliance also gets a grade and an estimated win chance, explained on `ratings.html`.
- `playoffs.html` — Playoff Selection: staff enter an event's alliances as they form, and the whole
  team sees them update. Beside them, every team at the event that hasn't been picked is ranked in
  a sortable table of ratings and raw stats. Each alliance has Red and Blue buttons that open it in
  the Alliance View. Alliances have 3 teams, or 4 at district championships and the FIRST
  Championship; staff can switch any event with the 4-team toggle. To change the table's stats,
  edit `COLUMNS` in the page.
- `bracket.html` — Playoff Bracket: the 2026 FRC 8-alliance double-elimination bracket for an event.
  Round 1 fills from the Playoff Selection alliances, and official results move alliances along, so
  it only advances once an event syncs. When official scores are tied, staff click who won the
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

**Competition-day auto-sync** refreshes one staff-chosen event from FRC/TBA at every 5-minute mark
of the clock (9:35, 9:40, 9:45...). It runs on the server through `pg_cron`, so nobody has to keep
a page open, and turns itself off 4 days after the event date. `SQL/rebuild_all.sql` enables pg_cron
and pg_net and schedules the job. The one manual step is storing `sync_secret` in the Vault (section 15).
The check query at the end of that file shows if either is missing, and the Staff Portal warns if a
run is failing.

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
