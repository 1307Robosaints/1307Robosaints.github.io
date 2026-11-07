# 1307Robosaints.github.io

Public website and **1307scout** scouting app for St. Thomas Aquinas Robotics Team 1307
(Dover, NH). Plain static HTML/CSS/JS — no build step required to run it, no bundler, no
framework. Hosted on GitHub Pages at [robosaints1307.com](https://robosaints1307.com) (see `CNAME`).

## Site map

**Public pages** — no account needed:
`index.html`, `about-the-students.html`, `about-the-mentors.html`, `about-the-robot.html`,
`oursponsors.html`, `business-plan.html`, `Gallery/gallery.html`, `contact.html`,
`privacy-policy.html`, `terms-of-service.html`.

**1307scout** — the team's scouting app, gated by sign-in (`signin.html`, `account.html`):
- `1307scout.html` — landing/command-center page, links out based on your access level.
- `scout.html` — enter match and pit scouting data for the current event (or view a limited
  slice of data via a share code, no account needed).
- `query.html` — Team Database: every team's scouted and official match history, pit/robot
  parameters, and two independent ratings (one from human scouting, one from synced official
  results — see the comment on `team_ratings()` in `SQL/rebuild_all.sql` for why they're kept separate).
  A team's card also shows its name and logo if staff have set one on the Team Info tab.
- `portal.html` — staff-only admin: events, scouting form fields, share codes, test-team tags,
  team names/logos, member access levels, and an audit log of who changed what and when (staff,
  mentor/student, guest, or system actions are tagged separately, with a searchable/filterable list).

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

Robot photos uploaded from the Scout page land in a public Supabase Storage bucket
(`scouting-photos`), created by `rebuild_all.sql`.

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
