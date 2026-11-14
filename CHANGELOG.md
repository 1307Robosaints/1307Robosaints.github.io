# Changelog

1307scout stable releases (scout.robosaints1307.com) and the informational site
(robosaints1307.com). Versioning and cadence: see `RELEASING.md`. Newest first.

## 0.0.4 (2026-11-13)

### Informational site (robosaints1307.com)

- Our Sponsors has a "Contact us about sponsoring" button, which opens the contact form with
  Sponsorships already ticked.

### 1307scout (scout.robosaints1307.com)

- The "Install the app" button works: it opens the browser's install prompt, and it only shows in
  browsers that can install from a button (Chrome, Edge, Android). Others follow the install steps.

## 0.0.3 (2026-11-12)

### Informational site (robosaints1307.com)

- **Business Plan** (Sponsors menu) is no longer a placeholder: the team's official 2026 business
  plan, with our mission, growth, future plans, organizational structure, event history,
  expenditures, sponsorship levels, how to donate by check, and who to contact.
- Our Sponsors explains why to sponsor the team and links to the sponsorship levels.
- Light or dark theme now matches across this site, 1307scout and the beta site.

## 0.0.2 (2026-11-11)

### Informational site (robosaints1307.com)

- **Season Results** (About Us menu) is new: every event Team 1307 has played since our rookie
  year in 2004, by season, with records, ranks, playoff finishes, awards and every match. Past
  seasons come from The Blue Alliance; this season updates on its own during competitions.
- A highlight reel at the top of Season Results shows all four of our event wins: 2015 Granite
  State, 2019 Greater Boston, 2022 Battle of the Bay and 2026 Pine Tree.
- The privacy policy covers the new features below (scout shifts, pick list, robot log, match
  alerts, scouting-quality checks, QR hand-off, CSV exports, FRC Nexus).

### 1307scout (scout.robosaints1307.com)

- **Scout Shifts**: staff give scouts a driver-station seat for a range of matches. The Scout page
  shows your next seat and team, and **Fill in** starts that entry.
- **Pick List**: staff's ranked list for alliance selection, with tiers and notes. Playoff Selection
  shows each team's place on it and the best team still available.
- **Pit Crew**: our robot's pre-match checklist, batteries, repairs and notes.
- **Match alerts**: turn on a notification per device on My Account, sent shortly before a team
  needs to queue (from FRC Nexus where the event uses it).
- **Offline QR hand-off**: an offline scout can show a draft as a QR code, and a teammate who is
  online scans it in.
- **Vision pre-fill**: once vision has proven itself at an event, new entries start with its answer
  for "left starting zone" (marked for the scout to check) and show its FUEL estimate as a hint.
- The 1307scout home page shows our next match at the default event, linked to its strategy plan.
- Team Database: trend charts, a searchable list of scouted notes, and **Export CSV**.
- Match Flags: vision vs scouts agreement, and (staff) scout accuracy.
- Our Matches saves each win-chance prediction, and How Ratings Work shows how they held up.

### Behind the scenes

- beta.robosaints1307.com now runs the whole site, public pages included, and installs as
  "1307scout beta" beside the stable app.
- Vision worker: automatic calibration, robot number reading and appearance training.

## 0.0.1 (2026-11-11)

The first stable release, the site as of commit `dd1d335` ("Image size fix").

- 1307scout moves to scout.robosaints1307.com. robosaints1307.com is now the informational site,
  and links to 1307scout pages there redirect to the new address.
- Experimental 1307scout runs at beta.robosaints1307.com, built from `master`.
