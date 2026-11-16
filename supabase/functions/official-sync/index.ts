// supabase/functions/official-sync/index.ts
//
// Pulls official match data from FRC Events (FIRST) and The Blue Alliance (TBA)
// into public.official_matches. Deploy with:
//   supabase functions deploy official-sync --no-verify-jwt
// (auth is checked inside the function, so the cron job doesn't need a JWT)
//
// WHO CAN CALL IT
//   - pg_cron / curl, with the header  x-sync-secret: <SYNC_SECRET>
//   - a signed-in STAFF user (Staff Portal "Sync now" button), via their login token
//
// REQUEST BODY (all optional)
//   { "event_id": "<uuid>" }  sync just this event: ignores the date window,
//                             the 90 s throttle, and cached Last-Modified / ETag values
//   { "force": true }         same, for every linked event
//   { "debug": true }         fetch + map but DON'T write; returns raw samples so you
//                             can check field names (combine with event_id)
//   {}                        normal cron run: only events inside their date window
//                             that haven't synced in the last 90 s
//
// SECRETS (supabase secrets set ...)
//   FRC_API_USER, FRC_API_TOKEN, TBA_API_KEY, SYNC_SECRET
//   EVENT_TZ  optional, default America/New_York: the zone for FRC's event-local times when the
//             event has none (events.timezone, filled from TBA here or by team-events)
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY are provided automatically.
//
// FRC Events API terms: link back to https://frc-events.firstinspires.org/services/API
// somewhere on the site, and don't use the data commercially.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const env = (k: string) => Deno.env.get(k) ?? "";
const SB_URL = env("SUPABASE_URL");
const SB_ANON = env("SUPABASE_ANON_KEY");
const SB_SERVICE = env("SUPABASE_SERVICE_ROLE_KEY");
const FRC_USER = env("FRC_API_USER");
const FRC_TOKEN = env("FRC_API_TOKEN");
const TBA_KEY = env("TBA_API_KEY");
const SYNC_SECRET = env("SYNC_SECRET");
const EVENT_TZ = env("EVENT_TZ") || "America/New_York";

const FRC_BASE = "https://frc-api.firstinspires.org/v3.0";
const TBA_BASE = "https://www.thebluealliance.com/api/v3";

const THROTTLE_MS = 90_000;        // skip an event synced less than this long ago
const DAY_MS = 86_400_000;
const WINDOW_BEFORE = 1 * DAY_MS;  // auto-sync starts 1 day before event_date...
const WINDOW_AFTER = 4 * DAY_MS;   // ...and stops 4 days after it

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-sync-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });

// ── Types ───────────────────────────────────────────────────────────────
interface EventRow {
  id: string;
  name: string;
  event_date: string | null;
  frc_event_code: string | null;
  tba_event_key: string | null;
  official_synced_at: string | null;
  tba_etag: string | null;
  frc_last_modified: Record<string, string> | null;
  timezone: string | null;
}
interface MatchRow {
  event_id: string;
  source: "frc" | "tba";
  match_key: string;               // qm12, sf8m1, f1m2: identical on both sources
  comp_level: "qm" | "sf" | "f";
  set_number: number;
  match_number: number;
  played_at: string | null;
  red_teams: number[];
  blue_teams: number[];
  red_score: number | null;
  blue_score: number | null;
  red_breakdown: unknown | null;
  blue_breakdown: unknown | null;
  updated_at: string;
}
interface SourceResult {
  rows: MatchRow[];
  notes: string[];
  sample?: unknown;
  etag?: string | null;                       // TBA
  frcState?: Record<string, string>;          // FRC Last-Modified values to save after a good write
  notModified?: boolean;
}

class HttpError extends Error {
  constructor(public status: number, msg: string) { super(msg); }
}

// ── Helpers ─────────────────────────────────────────────────────────────
function safeEq(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
// deno-lint-ignore no-explicit-any
const num = (v: any): number | null =>
  v === null || v === undefined || v === "" || Number.isNaN(Number(v)) ? null : Number(v);

// FRC sends event-local times with no zone ("2026-03-20T10:05:00"). Convert them to a
// real UTC timestamp so they line up with TBA's epoch times.
function localToIso(local: string | null | undefined, tz: string): string | null {
  if (!local) return null;
  if (/(Z|[+-]\d\d:?\d\d)$/i.test(local)) {
    const d = new Date(local);
    return isNaN(d.getTime()) ? null : d.toISOString();
  }
  const asUtc = Date.parse(local + "Z");
  if (isNaN(asUtc)) return null;
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(asUtc));
  const g = (t: string) => Number(parts.find((p) => p.type === t)!.value);
  const tzAsUtc = Date.UTC(g("year"), g("month") - 1, g("day"), g("hour"), g("minute"), g("second"));
  return new Date(asUtc - (tzAsUtc - asUtc)).toISOString();
}

// A usable IANA zone name, or null
function validZone(z: string | null | undefined): string | null {
  if (!z) return null;
  try { new Intl.DateTimeFormat("en-US", { timeZone: z }); return z; } catch { return null; }
}
// The event's own zone; asks TBA once for an event that has none yet (saved by the caller)
async function eventZone(ev: EventRow): Promise<{ tz: string; found?: string }> {
  const own = validZone(ev.timezone);
  if (own) return { tz: own };
  if (ev.tba_event_key && TBA_KEY) {
    try {
      const r = await fetch(`${TBA_BASE}/event/${ev.tba_event_key}`, {
        headers: { "X-TBA-Auth-Key": TBA_KEY, Accept: "application/json" },
        signal: AbortSignal.timeout(10_000),
      });
      const found = r.ok ? validZone((await r.json())?.timezone) : null;
      if (found) return { tz: found, found };
    } catch { /* fall through to the default */ }
  }
  return { tz: EVENT_TZ };
}

// FRC playoff match numbers -> TBA-style keys (2023+ double elimination).
//   FRC playoff 1-13  = TBA sf{N}m1    (set N, match 1)
//   FRC playoff 14-16 = TBA f1m1..f1m3 (Finals; 17+ is overtime finals)
function frcKey(level: "qual" | "playoff", n: number) {
  if (level === "qual") {
    return { match_key: `qm${n}`, comp_level: "qm" as const, set_number: 1, match_number: n };
  }
  if (n >= 14) {
    return { match_key: `f1m${n - 13}`, comp_level: "f" as const, set_number: 1, match_number: n - 13 };
  }
  return { match_key: `sf${n}m1`, comp_level: "sf" as const, set_number: n, match_number: 1 };
}

// ── FRC Events ──────────────────────────────────────────────────────────
interface FrcResult {
  notModified?: boolean;
  // deno-lint-ignore no-explicit-any
  data?: any;
  lastModified?: string | null;
  failed?: string;
}

async function frcGet(path: string, lastModified?: string | null): Promise<FrcResult> {
  const headers: Record<string, string> = {
    Authorization: "Basic " + btoa(`${FRC_USER}:${FRC_TOKEN}`),
    Accept: "application/json",
  };
  if (lastModified) headers["If-Modified-Since"] = lastModified;
  const r = await fetch(`${FRC_BASE}/${path}`, { headers, signal: AbortSignal.timeout(15_000) });
  if (r.status === 304) return { notModified: true };
  if (!r.ok) throw new HttpError(r.status, `FRC ${path} -> HTTP ${r.status}`);
  return { data: await r.json(), lastModified: r.headers.get("Last-Modified") };
}

// deno-lint-ignore no-explicit-any
function splitTeams(teams: any[]) {
  const red: [number, number][] = [];
  const blue: [number, number][] = [];
  for (const t of teams ?? []) {
    const m = /^(red|blue)(\d)?/i.exec(String(t.station ?? ""));
    if (!m || t.teamNumber == null) continue;
    (m[1].toLowerCase() === "red" ? red : blue).push([Number(m[2] ?? 9), Number(t.teamNumber)]);
  }
  const ordered = (a: [number, number][]) => a.sort((x, y) => x[0] - y[0]).map((x) => x[1]);
  return { red: ordered(red), blue: ordered(blue) };
}

async function fetchFrc(ev: EventRow, season: number, full: boolean, nowIso: string, tz: string): Promise<SourceResult> {
  const notes: string[] = [];
  const sample: Record<string, unknown> = {};
  const byKey = new Map<string, MatchRow>();
  const before = full ? {} : (ev.frc_last_modified ?? {});
  const state: Record<string, string> = { ...(ev.frc_last_modified ?? {}) };
  let changed = false;

  for (const level of ["qual", "playoff"] as const) {
    // hybrid = the schedule (teams, times) with results (scores) merged in
    const sPath = `${season}/schedule/${ev.frc_event_code}/${level}/hybrid`;
    const dPath = `${season}/scores/${ev.frc_event_code}/${level}`;

    let sched: FrcResult;
    try {
      sched = await frcGet(sPath, before[sPath]);
    } catch (e) {
      if (e instanceof HttpError && (e.status === 400 || e.status === 404)) {
        notes.push(`FRC ${level}: nothing published yet`);
        continue;
      }
      throw e;
    }
    let scores: FrcResult = await frcGet(dPath, before[dPath])
      .catch((e) => ({ failed: String((e as Error).message ?? e) }));

    // Nothing new on either endpoint: skip this level
    if (sched.notModified && (scores.notModified || scores.failed)) {
      notes.push(`FRC ${level}: no changes`);
      continue;
    }
    // One changed: re-download the other so every row can be rebuilt completely
    if (sched.notModified) sched = await frcGet(sPath, null);
    if (scores.notModified) {
      scores = await frcGet(dPath, null).catch((e) => ({ failed: String((e as Error).message ?? e) }));
    }
    if (scores.failed) notes.push(`FRC ${level}: score details unavailable (${scores.failed})`);

    if (sched.lastModified) state[sPath] = sched.lastModified;
    if (scores.lastModified) state[dPath] = scores.lastModified;
    changed = true;

    const list = sched.data?.Schedule ?? sched.data?.schedule ?? [];
    const scoreList = scores.data?.MatchScores ?? scores.data?.matchScores ?? [];

    // Score details hold the per-alliance breakdown (FUEL, TOWER, fouls, ...)
    // deno-lint-ignore no-explicit-any
    const detail = new Map<number, Record<string, any>>();
    // deno-lint-ignore no-explicit-any
    for (const s of scoreList as any[]) {
      // deno-lint-ignore no-explicit-any
      const byColor: Record<string, any> = {};
      for (const a of s.alliances ?? s.Alliances ?? []) byColor[String(a.alliance).toLowerCase()] = a;
      detail.set(Number(s.matchNumber), byColor);
    }
    sample[level] = { schedule: list.slice(0, 1), scores: scoreList.slice(0, 1) };

    // deno-lint-ignore no-explicit-any
    for (const m of list as any[]) {
      const n = Number(m.matchNumber);
      if (!n) continue;
      const { red, blue } = splitTeams(m.teams);
      if (!red.length || !blue.length) continue; // bracket slot not decided yet

      const rs = num(m.scoreRedFinal), bs = num(m.scoreBlueFinal);
      const played = rs !== null && bs !== null && (m.postResultTime != null || rs > 0 || bs > 0);
      const d = detail.get(n);
      const row: MatchRow = {
        event_id: ev.id,
        source: "frc",
        ...frcKey(level, n),
        played_at: localToIso(m.actualStartTime ?? m.startTime, tz),
        red_teams: red,
        blue_teams: blue,
        red_score: played ? rs : null,
        blue_score: played ? bs : null,
        red_breakdown: d?.red ?? null,
        blue_breakdown: d?.blue ?? null,
        updated_at: nowIso,
      };
      // Replays can list the same match twice; keep the scored one
      const prev = byKey.get(row.match_key);
      if (!prev || row.red_score !== null) byKey.set(row.match_key, row);
    }
  }
  return { rows: [...byKey.values()], notes, sample, frcState: state, notModified: !changed };
}

// ── The Blue Alliance ───────────────────────────────────────────────────
async function fetchTba(ev: EventRow, full: boolean, nowIso: string): Promise<SourceResult> {
  const headers: Record<string, string> = { "X-TBA-Auth-Key": TBA_KEY, Accept: "application/json" };
  if (ev.tba_etag && !full) headers["If-None-Match"] = ev.tba_etag;

  const r = await fetch(`${TBA_BASE}/event/${ev.tba_event_key}/matches`, {
    headers,
    signal: AbortSignal.timeout(15_000),
  });
  if (r.status === 304) return { rows: [], notes: ["TBA: no changes"], notModified: true };
  if (!r.ok) throw new HttpError(r.status, `TBA matches -> HTTP ${r.status}`);

  // deno-lint-ignore no-explicit-any
  const matches: any[] = await r.json();
  const rows: MatchRow[] = [];
  let skipped = 0;

  for (const m of matches) {
    const level = m.comp_level;
    if (level !== "qm" && level !== "sf" && level !== "f") { skipped++; continue; }
    const key = String(m.key).split("_").slice(1).join("_"); // "2026nhdur_qm12" -> "qm12"
    const toTeams = (keys: string[]) => (keys ?? []).map((k) => Number(String(k).replace("frc", "")));
    const red = toTeams(m.alliances?.red?.team_keys);
    const blue = toTeams(m.alliances?.blue?.team_keys);
    if (!red.length || !blue.length) continue;

    // TBA uses -1 for "not played yet"
    const score = (v: unknown) => {
      const n = num(v);
      return n === null || n < 0 ? null : n;
    };
    const t = num(m.actual_time) ?? num(m.time);
    rows.push({
      event_id: ev.id,
      source: "tba",
      match_key: key,
      comp_level: level,
      set_number: Number(m.set_number ?? 1),
      match_number: Number(m.match_number),
      played_at: t ? new Date(t * 1000).toISOString() : null,
      red_teams: red,
      blue_teams: blue,
      red_score: score(m.alliances?.red?.score),
      blue_score: score(m.alliances?.blue?.score),
      red_breakdown: m.score_breakdown?.red ?? null,
      blue_breakdown: m.score_breakdown?.blue ?? null,
      updated_at: nowIso,
    });
  }
  const notes = skipped ? [`TBA: skipped ${skipped} matches with unsupported levels`] : [];
  return { rows, notes, sample: matches.slice(0, 1), etag: r.headers.get("ETag") };
}

// ── Main ────────────────────────────────────────────────────────────────
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  // Auth: cron secret, or a signed-in staff user
  let authed = safeEq(req.headers.get("x-sync-secret") ?? "", SYNC_SECRET);
  if (!authed) {
    const auth = req.headers.get("Authorization");
    if (auth?.startsWith("Bearer ")) {
      const userSb = createClient(SB_URL, SB_ANON, {
        global: { headers: { Authorization: auth } },
        auth: { persistSession: false },
      });
      const { data } = await userSb.rpc("is_staff");
      authed = data === true;
    }
  }
  if (!authed) return json({ error: "Not authorized" }, 401);

  const body = await req.json().catch(() => ({}));
  const eventId: string | null = typeof body.event_id === "string" ? body.event_id : null;
  const debug = body.debug === true;
  const full = body.force === true || !!eventId;   // ignore window, throttle, and cached validators

  const sb = createClient(SB_URL, SB_SERVICE, { auth: { persistSession: false } });

  let q = sb.from("events").select(
    "id,name,event_date,frc_event_code,tba_event_key,official_synced_at,tba_etag,frc_last_modified,timezone");
  q = eventId ? q.eq("id", eventId) : q.or("frc_event_code.not.is.null,tba_event_key.not.is.null");
  const { data: events, error: evErr } = await q;
  if (evErr) return json({ error: evErr.message }, 500);

  const nowMs = Date.now();
  const nowIso = new Date(nowMs).toISOString();
  const results: unknown[] = [];

  for (const ev of (events ?? []) as EventRow[]) {
    if (!full) {
      const d = ev.event_date ? Date.parse(ev.event_date + "T00:00:00Z") : NaN;
      if (Number.isNaN(d) || nowMs < d - WINDOW_BEFORE || nowMs >= d + WINDOW_AFTER) {
        results.push({ event: ev.name, skipped: "outside event window" });
        continue;
      }
      if (ev.official_synced_at && nowMs - Date.parse(ev.official_synced_at) < THROTTLE_MS) {
        results.push({ event: ev.name, skipped: "synced recently" });
        continue;
      }
    }

    const season = Number((ev.tba_event_key ?? "").slice(0, 4)) ||
      (ev.event_date ? Number(ev.event_date.slice(0, 4)) : new Date().getUTCFullYear());

    const out: Record<string, unknown> = { event: ev.name, season };
    const noteParts: string[] = [];
    const update: Record<string, unknown> = {};
    const status: Record<string, unknown> = { at: nowIso };
    let anyOk = false;

    // Each source runs on its own, so one failing never blocks the other
    const sources: Array<["frc" | "tba", () => Promise<SourceResult>]> = [];
    if (ev.frc_event_code) {
      if (FRC_USER && FRC_TOKEN) {
        // FRC sends event-local times, so work out the event's zone first
        const zone = await eventZone(ev);
        // Same pattern as the column's check, so a stray name can't fail the whole event update
        if (zone.found && !debug && /^[A-Za-z_]+(\/[A-Za-z0-9_+-]+)*$/.test(zone.found)) update.timezone = zone.found;
        sources.push(["frc", () => fetchFrc(ev, season, full, nowIso, zone.tz)]);
      } else noteParts.push("FRC: API credentials not set");
    }
    if (ev.tba_event_key) {
      if (TBA_KEY) sources.push(["tba", () => fetchTba(ev, full, nowIso)]);
      else noteParts.push("TBA: API key not set");
    }

    for (const [name, run] of sources) {
      try {
        const res = await run();
        if (debug) {
          out[name] = {
            would_write: res.rows.length,
            mapped_sample: res.rows.slice(0, 2),
            raw_sample: res.sample,
            notes: res.notes,
          };
          continue;
        }
        for (let i = 0; i < res.rows.length; i += 200) {
          const { error } = await sb.from("official_matches")
            .upsert(res.rows.slice(i, i + 200), { onConflict: "event_id,source,match_key" });
          if (error) throw new Error("database: " + error.message);
        }
        // Remember validators only after the rows are safely saved
        if (name === "tba" && res.etag) update.tba_etag = res.etag;
        if (name === "frc" && res.frcState) update.frc_last_modified = res.frcState;

        anyOk = true;
        const label = res.notModified ? "no changes" : `${res.rows.length} matches`;
        noteParts.push(`${name.toUpperCase()}: ${label}`, ...res.notes);
        out[name] = { matches: res.rows.length, notModified: !!res.notModified, notes: res.notes };
        status[name] = { status: res.notModified ? "not_modified" : "updated", matches: res.rows.length };
      } catch (e) {
        const msg = (e as Error).message;
        console.error(`[official-sync] ${ev.name} ${name}: ${msg}`);
        noteParts.push(`${name.toUpperCase()} failed: ${msg}`);
        out[name] = { error: msg };
        status[name] = { status: "error", error: msg };
      }
    }

    if (!debug) {
      if (anyOk) update.official_synced_at = nowIso;
      update.official_sync_status = status;
      update.official_sync_note = `${nowIso} | ${noteParts.join(" | ")}`.slice(0, 500);
      await sb.from("events").update(update).eq("id", ev.id);
    }
    results.push(out);
  }

  return json({ ok: true, debug, results });
});