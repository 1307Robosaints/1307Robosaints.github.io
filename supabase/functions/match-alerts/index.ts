// match-alerts: sends a push notification to everyone who turned on match alerts (My Account,
// js/alerts.js) shortly before their team needs to queue. run_match_alerts() in
// SQL/rebuild_all.sql (section 8q) calls it every 2 minutes while auto-sync is on for an event.
//
// Two sources, best first:
//   FRC Nexus     at events that run queuing on Nexus (https://frc.nexus): the alert goes out when
//                 the team's match is queuing, or its estimated queue time is QUEUE_MINUTES away.
//                 Needs the NEXUS_API_KEY secret, and the event's TBA key (Nexus uses the same keys).
//   FRC/TBA       everywhere else: the schedule and scores from official-sync, alerting when the
//                 team's next match is ALERT_AHEAD or fewer matches after the last one with a score.
//                 Scores post after a match, so this runs a few minutes behind the field.
//
// Request: POST { event_id } with the x-sync-secret header (same secret as official-sync).
// match_alerts_sent records each alert, so one match is announced once per team.
//
// Setup, once:
//   generate a VAPID key pair (npx web-push generate-vapid-keys)
//   supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT=mailto:<team address>
//   optional: supabase secrets set NEXUS_API_KEY=...   (from https://frc.nexus/api)
//   supabase functions deploy match-alerts --no-verify-jwt
//   then put the public key in js/auth-config.js as pushKey.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const ALERT_AHEAD = 3;     // FRC/TBA: matches before ours that the alert goes out
const QUEUE_MINUTES = 10;  // Nexus: alert this long before the estimated queue time
const NEXUS = "https://frc.nexus/api/v1";
const LEVEL: Record<string, number> = { qm: 0, sf: 1, f: 2 };

type Match = { match_key: string; red_teams: number[]; blue_teams: number[]; red_score: number | null; blue_score: number | null };
type Sub = { endpoint: string; p256dh: string; auth_key: string; team_number: number };
// What to tell one team about one match
type Alert = { team: number; key: string; title: string; body: string; url: string };

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}
function parseKey(key: string) {
  const m = /^(qm)(\d+)$|^sf(\d+)m(\d+)$|^f1m(\d+)$/.exec(key);
  if (!m) return null;
  if (m[1]) return { level: "qm", n: +m[2], game: 1 };
  if (m[3]) return { level: "sf", n: +m[3], game: +m[4] };
  return { level: "f", n: +m[5], game: 1 };
}
function label(key: string) {
  const k = parseKey(key)!;
  return k.level === "qm" ? `Qual ${k.n}` : k.level === "sf" ? `Playoff ${k.n}` : `Final ${k.n}`;
}
// Same rule as the pages: unplayed matches can come through as null, 0-0 or TBA's -1
function played(m: Match) {
  return m.red_score != null && m.blue_score != null && m.red_score >= 0 && m.blue_score >= 0 &&
    (m.red_score > 0 || m.blue_score > 0);
}
function sides(red: number[], blue: number[], team: number) {
  const isRed = red.includes(team);
  return `${isRed ? "Red" : "Blue"} with ${(isRed ? red : blue).filter((t) => t !== team).join(", ") || "—"} ` +
    `vs ${(isRed ? blue : red).join(", ")}`;
}
function strategyUrl(eventId: string, key: string | null) {
  return key ? `/strategy.html?event=${encodeURIComponent(eventId)}&match=${encodeURIComponent(key)}` : "/matches.html";
}

// ── FRC Nexus ───────────────────────────────────────────────────────
type NexusMatch = {
  label: string; status?: string; redTeams?: (string | null)[]; blueTeams?: (string | null)[];
  replayOf?: string | null; times?: { estimatedQueueTime?: number | null };
};
// The event's live status, or null when Nexus isn't running queuing there (or isn't set up)
async function nexusMatches(eventKey: string | null): Promise<NexusMatch[] | null> {
  const key = Deno.env.get("NEXUS_API_KEY");
  if (!key || !eventKey) return null;
  try {
    const r = await fetch(`${NEXUS}/event/${encodeURIComponent(eventKey)}`, { headers: { "Nexus-Api-Key": key } });
    if (!r.ok) return null;
    const data = await r.json() as { matches?: NexusMatch[] };
    return Array.isArray(data.matches) && data.matches.length ? data.matches : null;
  } catch {
    return null;
  }
}
// "Qualification 12" -> qm12, "Playoff 5" -> sf5m1, "Final 2" -> f1m2, for the strategy link
function nexusKey(lbl: string): string | null {
  const m = /^(Qualification|Playoff|Final)\s+(\d+)/i.exec(lbl);
  if (!m) return null;
  const n = Number(m[2]), kind = m[1].toLowerCase();
  return kind === "qualification" ? `qm${n}` : kind === "playoff" ? `sf${n}m1` : `f1m${n}`;
}
const teamsOf = (list?: (string | null)[]) => (list ?? []).map((t) => Number(t)).filter((t) => t > 0);

function nexusAlerts(matches: NexusMatch[], teams: number[], eventId: string, now: number): Alert[] {
  const out: Alert[] = [];
  for (const team of teams) {
    // The team's first match that isn't on the field yet
    const m = matches.find((x) => x.status !== "On field" &&
      (teamsOf(x.redTeams).includes(team) || teamsOf(x.blueTeams).includes(team)));
    if (!m) continue;
    const queueAt = m.times?.estimatedQueueTime ?? null;
    const queuing = m.status === "Now queuing" || m.status === "On deck";
    const soon = queueAt != null && queueAt - now <= QUEUE_MINUTES * 60000;
    if (!queuing && !soon) continue;
    const mins = queueAt == null ? null : Math.round((queueAt - now) / 60000);
    const when = m.status === "On deck" ? "is on deck"
      : queuing ? "is queuing now"
      : mins != null && mins > 0 ? `queues in about ${mins} min` : "queues soon";
    out.push({
      team, key: `nexus:${m.label}`.slice(0, 60),
      title: `${team}: ${m.label} ${when}`,
      body: sides(teamsOf(m.redTeams), teamsOf(m.blueTeams), team) + " · queue times from frc.nexus",
      url: strategyUrl(eventId, nexusKey(m.label)),
    });
  }
  return out;
}

// ── FRC Events / TBA (official-sync) ────────────────────────────────
function scheduleAlerts(order: Match[], teams: number[], eventId: string): Alert[] {
  const now = order.findIndex((m) => !played(m));
  if (now < 0) return [];
  const out: Alert[] = [];
  for (const team of teams) {
    const i = order.findIndex((m, idx) => idx >= now && (m.red_teams.includes(team) || m.blue_teams.includes(team)));
    if (i < 0 || i - now > ALERT_AHEAD) continue;
    const m = order[i], away = i - now;
    out.push({
      team, key: m.match_key,
      title: `${team}: ${label(m.match_key)} ${away === 0 ? "is up next" : `in ${away} match${away === 1 ? "" : "es"}`}`,
      body: sides(m.red_teams, m.blue_teams, team),
      url: strategyUrl(eventId, m.match_key),
    });
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Use POST." }, 405);
  const secret = (Deno.env.get("SYNC_SECRET") ?? "").trim();
  if (!secret || (req.headers.get("x-sync-secret") ?? "").trim() !== secret) {
    return reply({ error: "Wrong or missing sync secret." }, 401);
  }
  const pub = Deno.env.get("VAPID_PUBLIC_KEY"), priv = Deno.env.get("VAPID_PRIVATE_KEY");
  if (!pub || !priv) return reply({ error: "VAPID keys aren't set." }, 500);
  webpush.setVapidDetails(Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com", pub, priv);

  let body: { event_id?: unknown };
  try { body = await req.json(); } catch { return reply({ error: "Send JSON like { event_id }." }, 400); }
  if (typeof body.event_id !== "string") return reply({ error: "event_id is required." }, 400);
  const eventId = body.event_id;

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const [subs, ev, sent] = await Promise.all([
    db.from("push_subscriptions").select("endpoint,p256dh,auth_key,team_number"),
    db.from("events").select("tba_event_key").eq("id", eventId).maybeSingle(),
    db.from("match_alerts_sent").select("match_key,team_number").eq("event_id", eventId),
  ]);
  const failed = [subs, ev, sent].find((r) => r.error);
  if (failed) return reply({ error: failed.error!.message }, 500);
  if (!subs.data!.length) return reply({ result: "nobody subscribed" });
  const teams = [...new Set((subs.data as Sub[]).map((s) => s.team_number))];

  // Nexus when the event runs queuing on it, otherwise the synced schedule
  let alerts: Alert[], source: string;
  const nexus = await nexusMatches(ev.data?.tba_event_key ?? null);
  if (nexus) {
    alerts = nexusAlerts(nexus, teams, eventId, Date.now());
    source = "nexus";
  } else {
    const [official, edits] = await Promise.all([
      db.from("official_matches_combined").select("match_key,red_teams,blue_teams,red_score,blue_score").eq("event_id", eventId),
      db.from("match_schedule").select("match_key,red_teams,blue_teams").eq("event_id", eventId),
    ]);
    if (official.error || edits.error) return reply({ error: (official.error ?? edits.error)!.message }, 500);
    // The schedule in play order, with the Our Matches edits laid over the official line-ups
    const byKey = new Map<string, Match>();
    for (const m of official.data as Match[]) byKey.set(m.match_key, { ...m });
    for (const e of edits.data!) {
      const m = byKey.get(e.match_key) ?? { match_key: e.match_key, red_score: null, blue_score: null, red_teams: [], blue_teams: [] };
      byKey.set(e.match_key, { ...m, red_teams: e.red_teams, blue_teams: e.blue_teams });
    }
    const order = [...byKey.values()].filter((m) => parseKey(m.match_key)).sort((a, b) => {
      const x = parseKey(a.match_key)!, y = parseKey(b.match_key)!;
      return LEVEL[x.level] - LEVEL[y.level] || x.n - y.n || x.game - y.game;
    });
    alerts = scheduleAlerts(order, teams, eventId);
    source = "schedule";
  }

  const already = new Set((sent.data as { match_key: string; team_number: number }[]).map((s) => `${s.match_key}|${s.team_number}`));
  let pushed = 0;
  const gone: string[] = [];
  for (const a of alerts) {
    if (already.has(`${a.key}|${a.team}`)) continue;
    // Recorded first, so a slow send can't make the next run announce it again
    const ins = await db.from("match_alerts_sent").insert({ event_id: eventId, match_key: a.key, team_number: a.team });
    if (ins.error) continue;
    const payload = JSON.stringify({ title: a.title, body: a.body, tag: `match-${a.key}-${a.team}`, url: a.url });
    for (const s of (subs.data as Sub[]).filter((x) => x.team_number === a.team)) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_key } }, payload, { TTL: 600 });
        pushed++;
      } catch (e) {
        // 404/410: the browser dropped the subscription, so it's removed
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410) gone.push(s.endpoint);
      }
    }
  }
  if (gone.length) await db.from("push_subscriptions").delete().in("endpoint", gone);
  return reply({ result: "ok", source, pushed, removed: gone.length });
});
