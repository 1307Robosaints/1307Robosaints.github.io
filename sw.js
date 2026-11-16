/* =========================================================================================================
   sw.js – the 1307scout app's service worker (registered by /js/pwa.js on every page).

   It only keeps the site's own files and its CDN libraries on the device, so pages open with no
   connection. It never touches Supabase or any other API: data, sign-in and access control always
   go straight to the server, and nobody's scouting data is ever stored in these caches.

     Site pages and files   network first; the saved copy only if the network fails or stalls,
                            so an online visit always gets the latest version of the site
     CDN libraries          saved copy first (their URLs name an exact version, so they never change)
     everything else        not handled here at all

   It also shows the match alerts the server pushes (see the push handler near the end).

   Bump VERSION when the PRECACHE list changes; old caches are deleted when the new worker starts.
   ========================================================================================================= */
var VERSION = "v7";
var SITE_CACHE = "rs-site-" + VERSION;
var CDN_CACHE = "rs-cdn-" + VERSION;

// Saved at install, so these open offline even if this device never visited them
var PRECACHE = [
  "/1307scout.html", "/scout.html", "/signin.html", "/account.html", "/app.html", "/offline.html",
  "/matches.html", "/query.html", "/alliance.html", "/strategy.html", "/flags.html",
  "/playoffs.html", "/bracket.html", "/live.html", "/ratings.html",
  "/shifts.html", "/picklist.html", "/pitcrew.html", "/team.html", "/share.html",
  "/css/modern.css",
  "/vendor/bootstrap/css/bootstrap.min.css", "/vendor/jquery/jquery.min.js",
  "/vendor/bootstrap/js/bootstrap.bundle.min.js",
  "/js/theme.js", "/js/auth-config.js", "/js/auth.js", "/js/pwa.js", "/js/teams.js", "/js/ratings.js",
  "/js/opr.js", "/js/vision.js", "/js/resync.js", "/js/alliance.js", "/js/offline.js",
  "/js/schedule.js", "/js/bracket.js", "/js/visioncheck.js", "/js/alerts.js", "/js/team.js", "/js/tables.js", "/js/dialog.js",
  "/manifest.webmanifest", "/img/robosaintslogo.png", "/img/robosaintslogo-dark.png", "/img/app/icon-192.png"
];

// Hosts whose files are versioned libraries and fonts, safe to keep
var CDN_HOSTS = ["cdn.jsdelivr.net", "cdnjs.cloudflare.com", "fonts.googleapis.com", "fonts.gstatic.com"];

// How long a page waits on a stalled network (venue Wi-Fi) before using its saved copy
var NETWORK_TIMEOUT_MS = 4000;

self.addEventListener("install", function (e) {
  // One missing file shouldn't stop the whole install, so each is saved on its own
  e.waitUntil(caches.open(SITE_CACHE).then(function (cache) {
    return Promise.all(PRECACHE.map(function (url) {
      return fetch(url, { cache: "no-cache" }).then(function (r) {
        // A redirected response can't answer a page load, so it isn't kept
        if (r.ok && !r.redirected) return cache.put(url, r);
      }).catch(function () {});
    }));
  }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener("activate", function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) {
      return /^rs-/.test(k) && k !== SITE_CACHE && k !== CDN_CACHE;
    }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

// Pages and the site's files are saved under their path alone, so "?source=app" and the like share one copy
function siteKey(url) { return url.origin + url.pathname; }

function isCdn(url) { return CDN_HOSTS.indexOf(url.hostname) !== -1; }

// Pages, code, styles and the app's own icons are kept. Photos (the gallery, sponsor logos) aren't,
// so browsing the public site doesn't fill the device.
function worthKeeping(url) {
  var p = url.pathname;
  return /(\.html|\/)$/.test(p) || /^\/(js|css|vendor|img\/app)\//.test(p) ||
    p === "/manifest.webmanifest" || p === "/img/robosaintslogo.png";
}

// Network first. A stalled network falls back to the saved copy after a few seconds, but the
// network answer still updates the cache when it arrives.
function networkFirst(req, url) {
  var key = siteKey(url);
  var network = fetch(req).then(function (r) {
    if (r.ok && r.type === "basic" && !r.redirected && worthKeeping(url)) {
      var copy = r.clone();
      caches.open(SITE_CACHE).then(function (c) { c.put(key, copy); });
    }
    return r;
  });
  var saved = caches.open(SITE_CACHE).then(function (c) { return c.match(key); });

  return new Promise(function (resolve) {
    var done = false;
    function finish(r) { if (!done && r) { done = true; resolve(r); } }
    function fallback() {
      return saved.then(function (r) {
        if (r) return finish(r);
        // Nothing saved: wait for the network after all, or show the offline page for a page load
        return network.then(finish, function () {
          if (req.mode === "navigate") {
            return caches.match("/offline.html").then(function (o) {
              finish(o || new Response("Offline", { status: 503 }));
            });
          }
          finish(Response.error());
        });
      });
    }
    var timer = setTimeout(fallback, NETWORK_TIMEOUT_MS);
    network.then(function (r) { clearTimeout(timer); finish(r); }, function () { clearTimeout(timer); fallback(); });
  });
}

// Fetch a CDN file as CORS, so the saved copy also satisfies pages that check its integrity hash
function fetchCdn(u) { return fetch(u, { mode: "cors", credentials: "omit" }); }

// Saved copy first, fetched (and saved) once if it isn't here yet
function cacheFirst(req) {
  return caches.open(CDN_CACHE).then(function (c) {
    return c.match(req.url).then(function (hit) {
      if (hit) return hit;
      return fetchCdn(req.url).then(function (r) {
        if (r.ok) c.put(req.url, r.clone());
        return r;
      }, function () { return fetch(req); });
    });
  });
}

self.addEventListener("fetch", function (e) {
  var req = e.request;
  if (req.method !== "GET" || req.headers.has("range")) return;
  var url = new URL(req.url);

  if (url.origin === self.location.origin) {
    if (url.pathname === "/sw.js") return;
    e.respondWith(networkFirst(req, url));
  } else if (isCdn(url)) {
    e.respondWith(cacheFirst(req));
  }
  // Anything else (Supabase, hCaptcha, EmailJS, The Blue Alliance...) goes straight to the network
});

// Match alerts (js/alerts.js, supabase/functions/match-alerts): show the notification the server
// sent. The message only says which match is coming up; nothing in it is stored here.
self.addEventListener("push", function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "1307scout", {
    body: d.body || "", tag: d.tag || "match-alert", icon: "/img/app/icon-192.png",
    data: { url: typeof d.url === "string" && d.url.charAt(0) === "/" ? d.url : "/matches.html" }
  }));
});
// Tapping it opens the page it names, in an open 1307scout window if there is one
self.addEventListener("notificationclick", function (e) {
  e.notification.close();
  var url = new URL((e.notification.data && e.notification.data.url) || "/matches.html", self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(function (list) {
    var open = list.find(function (c) { return new URL(c.url).origin === self.location.origin && "focus" in c; });
    if (open) return open.navigate(url).then(function (c) { return (c || open).focus(); });
    return self.clients.openWindow(url);
  }));
});

// pwa.js sends the libraries and fonts each page loaded before this worker was in control,
// so they're saved too and the page can open offline next time
self.addEventListener("message", function (e) {
  var d = e.data || {};
  if (d.type !== "save" || !Array.isArray(d.urls)) return;
  e.waitUntil(caches.open(CDN_CACHE).then(function (c) {
    return Promise.all(d.urls.slice(0, 60).map(function (u) {
      var url;
      try { url = new URL(u); } catch (err) { return; }
      if (!isCdn(url)) return;
      return c.match(u).then(function (hit) {
        if (hit) return;
        return fetchCdn(u).then(function (r) {
          if (r.ok) return c.put(u, r);
        }).catch(function () {});
      });
    }));
  }));
});
