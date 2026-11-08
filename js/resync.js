// "Resync data" button for the pages that show official FRC/TBA results. It always refreshes the
// default event (the one starred in the Staff Portal), whatever event the page is showing. The
// server sends the request (resync_default_event() in SQL/rebuild_all.sql), so students can use it
// too; this waits for official-sync to answer, then calls the page's onDone to reload.
(function () {
  var POLL_MS = 2000;
  var GIVE_UP_MS = 90000;   // the server's request times out at 60 seconds

  function wait(ms) { return new Promise(function (resolve) { setTimeout(resolve, ms); }); }

  // official-sync's error body, in a sentence
  function failure(st) {
    if (st.error) return st.error;
    if (st.status === 401) return "the server's sync secret doesn't match official-sync's. Staff can see the details in the Staff Portal.";
    var msg = st.body || "";
    try { var b = JSON.parse(msg); msg = b.error || b.message || msg; } catch (e) {}
    return "official-sync answered with HTTP " + st.status + (msg ? ": " + msg : ".");
  }

  async function run(sb) {
    var r = await sb.rpc("resync_default_event");
    if (r.error) return { ok: false, msg: r.error.message };
    var req = r.data || {};
    var started = Date.now();
    while (Date.now() - started < GIVE_UP_MS) {
      var s = await sb.rpc("resync_status", { p_request: req.request_id });
      if (s.error) return { ok: false, msg: s.error.message, req: req };
      var st = s.data || {};
      if (st.done) {
        if (st.unknown || st.status === 200) return { ok: true, req: req };
        return { ok: false, msg: failure(st), req: req };
      }
      await wait(POLL_MS);
    }
    return { ok: false, slow: true, req: req };
  }

  window.RSResync = {
    // Adds the button to container. onDone({ eventId, syncedAt }) runs after a sync finishes.
    mount: function (container, onDone) {
      var sb = RS.sb;
      var wrap = document.createElement("div");
      wrap.className = "rs-resync";
      wrap.innerHTML = '<button type="button" class="btn btn-outline-secondary btn-sm" ' +
        'title="Pull the latest official results from FRC/TBA for the default event">' +
        '<i class="fa fa-refresh" aria-hidden="true"></i> Resync data</button>' +
        '<span class="rs-resync-msg" role="status"></span>';
      container.appendChild(wrap);
      var btn = wrap.querySelector("button"), icon = wrap.querySelector("i"), msg = wrap.querySelector("span");

      function say(text, warn) { msg.textContent = text; msg.classList.toggle("warn", !!warn); }

      btn.addEventListener("click", async function () {
        btn.disabled = true;
        icon.classList.add("fa-spin");
        say("Syncing…");
        var res = await run(sb);
        var name = res.req && res.req.event_name ? res.req.event_name : "the default event";
        if (res.ok) {
          var ev = await sb.from("events").select("official_synced_at").eq("id", res.req.event_id).maybeSingle();
          say("Synced " + name + ". Ratings catch up within a minute.");
          if (onDone) await onDone({ eventId: res.req.event_id, syncedAt: ev.data ? ev.data.official_synced_at : null });
        } else if (res.slow) {
          say("Still syncing " + name + " on the server. The page picks it up on its next refresh.");
        } else {
          say("Couldn't sync " + name + ": " + res.msg, true);
        }
        icon.classList.remove("fa-spin");
        btn.disabled = false;
      });
    }
  };
})();
