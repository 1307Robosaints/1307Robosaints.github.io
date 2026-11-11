# Branches, sites and releases

One codebase, two branches, three sites:

| Branch   | Site                                                         | What it is |
|----------|--------------------------------------------------------------|------------|
| `master` | [beta.robosaints1307.com](https://beta.robosaints1307.com)   | 1307scout **experimental**. Push and try it, same as always. |
| `stable` | [scout.robosaints1307.com](https://scout.robosaints1307.com) | 1307scout **stable**: released versions only. |
| `stable` | [robosaints1307.com](https://robosaints1307.com)             | The informational site (team, robot, sponsors, contact, results). |

`.github/workflows/deploy.yml` deploys on every push: `master` to beta, `stable` to both the
informational site and scout. `deploy/build.sh` makes each site from the same files. It replaces
pages that belong on the other site with redirect stubs, points links across the two sites, and
writes `version.json` and `window.RS_BUILD`. Locally nothing changes: open any page, or serve the
repo root.

**Both sites use the same Supabase project**, so experimental runs on real data. That means:

- **SQL changes have to be additive** while stable still uses the old shape. Add columns, tables
  and functions. Don't rename, drop or change the meaning of anything the current stable release
  reads. Do the cleanup in a later release, after stable has stopped using the old thing.
- **Edge Functions are shared too.** Deploying one from `master` changes it for stable as well, so
  keep it compatible with both, or deploy it at release time.
- Anything you enter while testing on beta goes into the real data.

## Version numbers

Versions are `MAJOR.MINOR.PATCH`, starting at `0.0.1`. The current one is in `VERSION`.

- **MAJOR**: major content additions (a new section of the app, a season's game rebuilt).
- **MINOR**: new features.
- **PATCH**: bugfixes and other minor fixes, including text and content edits on the informational site.

Raising a number resets the ones to its right to zero (`0.3.2` → `0.4.0`). Each release is tagged
`vX.Y.Z` and gets an entry in `CHANGELOG.md`. Experimental builds show as `<last release>+<commit>`
in the footer, alongside an "Experimental" bar.

## Cadence

- **Every two weeks**: a MINOR (or MAJOR) release of whatever has proven itself on beta.
- **Event freeze**: from one week before a competition until it ends, stable takes PATCH releases
  only. No new features go to stable right before or during an event.
- **PATCH releases can ship anytime** they're needed.

"Proven" means it has been used on beta for real, not just loaded once: scouted a practice match,
opened on a phone, worked offline if the feature is meant to.

## Making a release (MINOR / MAJOR)

```sh
git checkout stable && git pull
git merge --no-ff master             # or the specific master commit that was proven
# edit VERSION, and add the release to the top of CHANGELOG.md
git commit -am "Release 0.1.0"
git tag v0.1.0
git push origin stable --follow-tags
git checkout master && git merge stable && git push   # brings VERSION/CHANGELOG back to master
```

Run any SQL the release needs before you push. Since changes are additive, it's usually already
been run.

## Bugfix on stable (PATCH)

Fix it on `stable` itself, so you don't ship unfinished work from `master` along with it:

```sh
git checkout stable && git pull
# fix, bump PATCH in VERSION, add a CHANGELOG.md line
git commit -am "Release 0.1.1: <what>"
git tag v0.1.1
git push origin stable --follow-tags
git checkout master && git merge stable && git push   # so the fix isn't lost on master
```

## One-time setup

Done once when switching to this workflow (November 2026). Kept here as a record.

Do the steps in order. Nothing changes on the live site until step 4.

### 1. DNS (Network Solutions, where robosaints1307.com is registered)

1. Sign in at networksolutions.com. Under **Domains**, open **robosaints1307.com**, then the **DNS** tab.
2. Click **+ Add Record**: type **CNAME**, name **`scout`**, points to
   **`1307robosaints.github.io`**. Leave the TTL at its default.
3. Add a second one the same way, with name **`beta`**.
4. Leave the existing records alone: the `www` CNAME and the four `A` records to `185.199.x.153`.
   The informational site still uses them.

The records can take up to a few hours to work. To check, run `nslookup scout.robosaints1307.com`:
once it's working, the output names `1307robosaints.github.io` with `185.199.x.153` addresses.

*Recommended:* also verify the domain with GitHub, so no one else's repo can claim one of its
subdomains. Go to github.com → the **1307Robosaints** organization → **Settings → Pages → Add a
domain**, enter `robosaints1307.com`, and add the `TXT` record it shows in the same DNS screen.

### 2. The two site repos (GitHub)

Do this for **`1307scout`** (domain `scout.robosaints1307.com`), then again for
**`1307scout-beta`** (domain `beta.robosaints1307.com`).

1. Go to github.com/new. Owner: **1307Robosaints**. Repository name: `1307scout`. Make it
   **Public** (Pages on a free organization needs a public repo). Tick **Add a README file**, so a
   `main` branch exists for Pages to point at. The first deploy replaces the README anyway.
2. In the new repo: **Settings → Pages**. Under *Build and deployment*, set Source to **Deploy from
   a branch**, branch **`main`**, folder **`/ (root)`**, then **Save**.
3. Under **Custom domain** on the same screen, type `scout.robosaints1307.com` and **Save**. The
   DNS check passes once step 1 has taken effect. Until then it shows a warning, which is fine.
4. Come back later (the certificate can take up to a day) and tick **Enforce HTTPS**.

If you name the repos something else, change `SCOUT_REPO` / `BETA_REPO` at the top of
`.github/workflows/deploy.yml`.

### 3. Deploy keys

These let this repo's workflow push the built site into the two repos, and only those two. Each
repo needs its own pair of keys. To make a pair (Git Bash):

```sh
ssh-keygen -t ed25519 -N "" -C "1307scout deploy" -f scout_deploy_key
ssh-keygen -t ed25519 -N "" -C "1307scout-beta deploy" -f beta_deploy_key
```

For each pair:

1. **Public half, into the site repo.** In `1307scout` (or `1307scout-beta`): **Settings → Deploy
   keys → Add deploy key**. Title: `deploy from 1307Robosaints.github.io`. Key: paste the whole
   contents of `scout_deploy_key.pub` (or `beta_deploy_key.pub`), one line starting
   `ssh-ed25519`. **Tick "Allow write access"**, then **Add key**.
2. **Private half, into this repo.** In `1307Robosaints.github.io`: **Settings → Secrets and
   variables → Actions → New repository secret**. Name: `SCOUT_DEPLOY_KEY` (or
   `BETA_DEPLOY_KEY`). Secret: paste the whole contents of `scout_deploy_key` (the file with no
   extension), including the `-----BEGIN OPENSSH PRIVATE KEY-----` and `-----END ...-----` lines.
   Then **Add secret**.

When both are in, delete the four key files. If a key is ever lost, make a new pair the same way.

### 4. This repo's Pages (the switch)

From this point, pushing `master` stops updating robosaints1307.com.

1. In `1307Robosaints.github.io`: **Settings → Pages**. Under *Build and deployment*, change
   Source from *Deploy from a branch* to **GitHub Actions**. Check that **Custom domain** still says
   `robosaints1307.com`.
2. **Settings → Environments → `github-pages`**. Under *Deployment branches and tags*, if it says
   *Selected branches and tags*, click **Add deployment branch or tag rule**, enter **`stable`**, and
   add it. Without this, the informational site's deploy is refused. (If `github-pages` isn't there
   yet, do step 7 first. The info deploy fails and creates the environment; then add the rule
   and re-run the job from the Actions tab.)

### 5. Supabase

In the Supabase dashboard, open the project, then **Authentication → URL Configuration**.

1. **Site URL**: change it to `https://scout.robosaints1307.com`. Supabase falls back to it in
   sign-up and password emails.
2. **Redirect URLs → Add URL**: add `https://scout.robosaints1307.com/**`, then
   `https://beta.robosaints1307.com/**`. **Save**. Without these, Google sign-in and password-reset
   links send people back to the wrong site.
3. Leave the existing `robosaints1307.com` entries until everyone has moved over.

Google sign-in needs no change in Google Cloud: Google returns to Supabase's own address, not ours.

### 6. hCaptcha

At dashboard.hcaptcha.com, go to **Sites**, open the site key that sign-in uses, and add
`scout.robosaints1307.com` and `beta.robosaints1307.com` to its **Domains**. Save. Without this,
every sign-in on the new sites fails the captcha check.

### 7. Push and check

```sh
git push origin stable --follow-tags   # deploys robosaints1307.com and scout.robosaints1307.com
git push origin master                 # deploys beta.robosaints1307.com
```

Watch the **Actions** tab in `1307Robosaints.github.io`: each push runs *Deploy sites*, and every
job should go green. Then check:

- robosaints1307.com: the public pages load, and the 1307scout menu links go to scout.robosaints1307.com.
- robosaints1307.com/scout.html redirects to scout.robosaints1307.com/scout.html.
- scout.robosaints1307.com: opens the 1307scout home page, and sign-in works (email and Google).
  `scout.robosaints1307.com/version.json` says `0.0.1`. (0.0.1 predates the footer version line,
  so the footer shows it from the next release on.)
- beta.robosaints1307.com: same, plus the orange Experimental bar at the bottom and the version in
  the footer, once the `js/auth.js` change that adds them is committed on `master`.

If a deploy job fails with a permission or "key" error, the deploy key is missing write access,
or its secret holds the wrong half of the key.

What moving the domain does to people already using 1307scout: every site keeps its own sign-in,
saved offline data, and installed app. So, at the switch:

- Everyone signs in again at scout.robosaints1307.com.
- **Unsent offline scouting drafts stay behind on the old address.** Have scouts send them before
  the switch, and do the switch outside competition season.
- An installed app has to be reinstalled from the new address. The old one opens robosaints1307.com,
  which now sends it to the new site in a browser tab. Its service worker removes itself.
- Match alerts have to be turned on again on My Account.
