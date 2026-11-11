#!/usr/bin/env bash
# Builds one of the three sites from this checkout (run by .github/workflows/deploy.yml; see RELEASING.md).
#
#   bash deploy/build.sh info  <out>   robosaints1307.com        public pages, from `stable`
#   bash deploy/build.sh scout <out>   scout.robosaints1307.com  1307scout, from `stable`
#   bash deploy/build.sh beta  <out>   beta.robosaints1307.com   the whole site, experimental, from `master`
#
# The repo itself stays one codebase that works when opened locally. This only:
#   - leaves out files the sites don't serve (SQL, vision worker, Edge Functions, docs, template leftovers)
#   - info and scout: replaces pages that belong on the other site with redirect stubs, so old links
#     and bookmarks work (beta keeps every page, so browsing never leaves it)
#   - points links at the other site directly, so they don't bounce through a stub
#   - on the info site, removes the app (manifest, pwa.js) and ships a service worker that uninstalls itself
#   - writes CNAME and version.json, and puts window.RS_BUILD in every page's <head> (js/auth.js reads it)
# Every root .html page not listed in PUBLIC is treated as a 1307scout page.
set -euo pipefail

TARGET="${1:?usage: build.sh info|scout|beta <out-dir>}"
OUT="${2:?usage: build.sh info|scout|beta <out-dir>}"

INFO_HOST="robosaints1307.com"
SCOUT_HOST="scout.robosaints1307.com"
BETA_HOST="beta.robosaints1307.com"

# Pages that live on the informational site
PUBLIC=(index about-the-mentors about-the-robot about-the-students business-plan contact
        oursponsors privacy-policy terms-of-service results Gallery/gallery)

case "$TARGET" in
  info)  HOST="$INFO_HOST";  CHANNEL="stable" ;;
  scout) HOST="$SCOUT_HOST"; CHANNEL="stable" ;;
  beta)  HOST="$BETA_HOST";  CHANNEL="experimental" ;;
  *) echo "unknown target: $TARGET" >&2; exit 1 ;;
esac
APP_HOST="$SCOUT_HOST"; [ "$TARGET" = beta ] && APP_HOST="$BETA_HOST"

SRC="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d ' \r\n' < "$SRC/VERSION")"
COMMIT="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ "$CHANNEL" = experimental ] && VERSION="$VERSION+$COMMIT"

# ── Copy the served files ──
rm -rf "$OUT"; mkdir -p "$OUT"
tar -C "$SRC" -cf - \
  --exclude=./.git --exclude=./.github --exclude=./deploy --exclude=./SQL --exclude=./supabase \
  --exclude=./vision --exclude=./node_modules --exclude=./_site --exclude='./*.md' \
  --exclude=./package.json --exclude=./package-lock.json --exclude=./gulpfile.js \
  --exclude=./.travis.yml --exclude=./.gitignore --exclude=./.gitattributes --exclude=./CNAME \
  --exclude=./VERSION --exclude=./Gallery/node_modules --exclude=./Gallery/package.json \
  --exclude=./Gallery/package-lock.json --exclude=./Gallery/gulpfile.js \
  . | tar -C "$OUT" -xf -
cd "$OUT"

is_public() { local p; for p in "${PUBLIC[@]}"; do [ "$p" = "$1" ] && return 0; done; return 1; }

# A page that moved to the other site: keeps the query string and #hash
stub() {
  cat > "$1" <<EOF
<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="robots" content="noindex">
<title>Moved</title>
<link rel="canonical" href="$2">
<script>location.replace("$2" + location.search + location.hash);</script>
<noscript><meta http-equiv="refresh" content="0;url=$2"></noscript>
</head><body><p>This page moved to <a href="$2">$2</a>.</p></body></html>
EOF
}

# Rewrites href="/<page>.html..." in every remaining page to the other site
relink() {
  local page="$1" host="$2" f
  for f in $(find . -name '*.html' -not -path './vendor/*'); do
    grep -q "Moved</title>" "$f" && continue
    sed -i "s#href=\"/$page\.html#href=\"https://$host/$page.html#g" "$f"
  done
}

PAGES=$(find . -maxdepth 1 -name '*.html' | sed 's#^\./##; s#\.html$##'; echo Gallery/gallery)

if [ "$TARGET" = info ]; then
  for p in $PAGES; do
    is_public "$p" && continue
    stub "$p.html" "https://$APP_HOST/$p.html"
    relink "$p" "$APP_HOST"
  done
  # Not an app here: drop the install tags and pwa.js, and remove the old app's service worker
  # and caches from browsers that installed 1307scout on this domain before it moved.
  for f in $(find . -name '*.html' -not -path './vendor/*'); do
    sed -i -e '/rel="manifest"/d' -e '/mobile-web-app-capable/d' -e '/apple-mobile-web-app-title/d' \
           -e '/1307scout app (PWA)/d' -e '/src="\/js\/pwa\.js"/d' "$f"
  done
  rm -f manifest.webmanifest
  cat > sw.js <<'EOF'
// 1307scout moved to its own site, so this worker clears the old app's caches and uninstalls itself.
self.addEventListener("install", function () { self.skipWaiting(); });
self.addEventListener("activate", function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return /^rs-/.test(k); }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.registration.unregister(); }));
});
EOF
elif [ "$TARGET" = scout ]; then
  for p in $PAGES; do
    is_public "$p" || continue
    if [ "$p" = index ]; then stub index.html "/1307scout.html"; continue; fi
    stub "$p.html" "https://$INFO_HOST/$p.html"
    relink "$p" "$INFO_HOST"
  done
  relink index "$INFO_HOST"
else
  # Beta is the whole site, public pages included, so browsing never leaves it and changes to
  # the public pages can be tried out before a release too. It stays out of search results.
  printf 'User-agent: *\nDisallow: /\n' > robots.txt
  # Installed next to the stable app, it needs its own name
  sed -i -e 's#"name": "1307scout"#"name": "1307scout beta"#' \
         -e 's#"short_name": "1307scout"#"short_name": "1307scout β"#' manifest.webmanifest
  for f in $(find . -name '*.html' -not -path './vendor/*'); do
    sed -i 's#name="apple-mobile-web-app-title" content="1307scout"#name="apple-mobile-web-app-title" content="1307scout β"#' "$f"
  done
fi

# ── Domain, version, build marker ──
echo "$HOST" > CNAME
BUILD="{\"version\":\"$VERSION\",\"channel\":\"$CHANNEL\",\"commit\":\"$COMMIT\",\"site\":\"$TARGET\"}"
echo "$BUILD" > version.json
for f in $(find . -name '*.html' -not -path './vendor/*'); do
  grep -q "Moved</title>" "$f" && continue
  sed -i "0,/<head>/s#<head>#<head>\n<script>window.RS_BUILD = $BUILD;</script>#" "$f"
done
echo "Built $TARGET ($HOST) $VERSION into $OUT"
