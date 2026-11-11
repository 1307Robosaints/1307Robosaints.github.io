// Match alerts: a push notification when a team's next match is 3 or fewer matches away, while
// auto-sync is on for the event. This file turns them on and off for this browser (My Account);
// the server side is push_subscribe() in SQL/rebuild_all.sql (section 8q) and the match-alerts
// Edge Function. AUTH_CONFIG.pushKey is the public VAPID key; until it's set, alerts are off.
(function () {
  function key() { return (window.AUTH_CONFIG && AUTH_CONFIG.pushKey) || ""; }
  function supported() {
    return "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  }
  // The VAPID key comes as base64url text; the browser wants bytes
  function keyBytes(b64) {
    var pad = "=".repeat((4 - b64.length % 4) % 4);
    var raw = atob((b64 + pad).replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(raw, function (c) { return c.charCodeAt(0); });
  }
  async function current() {
    if (!supported()) return null;
    var reg = await navigator.serviceWorker.getRegistration();
    return reg ? reg.pushManager.getSubscription() : null;
  }
  // { on, team } for this browser, from the server's copy of its subscription
  async function status(sb) {
    var sub = await current();
    if (!sub) return { on: false };
    var r = await sb.from("push_subscriptions").select("team_number").eq("endpoint", sub.endpoint).maybeSingle();
    return { on: !!(r.data), team: r.data ? r.data.team_number : null };
  }
  async function enable(sb, team) {
    if (!supported()) throw new Error("This browser can't show notifications from a website.");
    if (!key()) throw new Error("Match alerts aren't set up on the server yet.");
    if (await Notification.requestPermission() !== "granted") throw new Error("Notifications are blocked for this site. Allow them in the browser's settings.");
    var reg = await navigator.serviceWorker.ready;
    var sub = await reg.pushManager.getSubscription() ||
      await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(key()) });
    var j = sub.toJSON();
    var r = await sb.rpc("push_subscribe", { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_team: team || 1307 });
    if (r.error) throw new Error(r.error.message);
  }
  async function disable(sb) {
    var sub = await current();
    if (!sub) return;
    await sb.rpc("push_unsubscribe", { p_endpoint: sub.endpoint });
    await sub.unsubscribe();
  }
  window.RSAlerts = { supported: supported, configured: function () { return !!key(); }, status: status, enable: enable, disable: disable };
})();
