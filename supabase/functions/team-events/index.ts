// team-events: reads which events each team on 1307scout is registered for this season, from The
// Blue Alliance and the FRC Events API, into event_teams, so each team's default event can follow
// its season (SQL/rebuild_all.sql section 5b). An event a team is registered for that isn't in
// the events table yet is added (auto_added), linked to its TBA key and FRC code. It also fills
// in start_date, end_date and timezone for linked events, which smart auto-sync needs. A new
// event's event_date follows this project's rule: the day before its last day. Last, it calls
// refresh_team_default_events() so the picks move at once.
//
// Request: POST {} for every team (pg_cron, daily: run_team_events_sync()), or { team_number }
// for one (Team Management's "Check FRC and TBA now": refresh_my_team_events()), with the
// x-sync-secret header (same secret as official-sync).
//
// Deploy:  supabase functions deploy team-events --no-verify-jwt
// It uses secrets official-sync already has: FRC_API_USER, FRC_API_TOKEN, TBA_API_KEY, SYNC_SECRET.
import { createClient } from "npm:@supabase/supabase-js@2";

const FRC = "https://frc-api.firstinspires.org/v3.0";
const TBA = "https://www.thebluealliance.com/api/v3";
const FILL_LIMIT = 40;   // events per run that get their dates and time zone filled in

type Found = {
  tba: string | null; frc: string | null; name: string; start: string | null; end: string | null;
  tz: string | null; location: string | null; tier: string;
};
type EventRow = {
  id: string; name: string; event_date: string | null; start_date: string | null; end_date: string | null; timezone: string | null;
  tba_event_key: string | null; frc_event_code: string | null; location: string | null;
};

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

// GET some JSON: the parsed body, "missing" for a 404, or null if the request failed
async function getJson(url: string, headers: Record<string, string>): Promise<unknown> {
  try {
    const r = await fetch(url, { headers: { Accept: "application/json", ...headers } });
    if (r.status === 404) return "missing";
    if (!r.ok) return null;
    return await r.json();
  } catch {
    return null;
  }
}

// This project's event_date: the day before the last day (the first day of matches), never before the start
function eventDate(start: string | null, end: string | null): string | null {
  if (!start || !end || end <= start) return start ?? end;
  const d = new Date(end + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() - 1);
  return d.toISOString().slice(0, 10);
}
const day = (s: unknown) => typeof s === "string" && /^\d{4}-\d{2}-\d{2}/.test(s) ? s.slice(0, 10) : null;
const tbaKey = (s: unknown) => typeof s === "string" && /^[0-9]{4}[a-z0-9]+$/.test(s) ? s : null;
const frcCode = (s: unknown) => typeof s === "string" && /^[A-Za-z0-9]{2,12}$/.test(s) ? s.toUpperCase() : null;
function zone(s: unknown): string | null {
  if (typeof s !== "string" || !/^[A-Za-z_]+(\/[A-Za-z0-9_+-]+)*$/.test(s) || s.length > 64) return null;
  try { new Intl.DateTimeFormat("en-US", { timeZone: s }); return s; } catch { return null; }
}
function place(city: unknown, state: unknown, country: unknown): string | null {
  const parts = [city, state || country].filter((x) => typeof x === "string" && x.trim()) as string[];
  return parts.length ? parts.join(", ").slice(0, 80) : null;
}

// TBA event_type: 0 regional, 1 district, 2 district champs, 5 its division, 3 champs division,
// 4 champs finals; everything else (off-season, preseason, unlabeled) counts as off-season
function tbaTier(t: unknown): string {
  if (t === 0 || t === 1) return "qualifier";
  if (t === 2 || t === 5) return "district_championship";
  if (t === 3 || t === 4) return "championship";
  return "offseason";
}
function frcTier(t: unknown): string {
  const s = String(t ?? "");
  if (s === "Regional" || s === "DistrictEvent") return "qualifier";
  if (s.startsWith("DistrictChampionship")) return "district_championship";
  if (s.startsWith("Championship")) return "championship";
  return "offseason";
}

// A team's events from TBA, or null if TBA couldn't be read. A team TBA doesn't know has none.
async function fromTba(team: number, season: number): Promise<Found[] | null> {
  const key = Deno.env.get("TBA_API_KEY");
  if (!key) return null;
  const data = await getJson(`${TBA}/team/frc${team}/events/${season}`, { "X-TBA-Auth-Key": key });
  if (data === "missing") return [];
  if (!Array.isArray(data)) return null;
  return data.map((e: Record<string, unknown>) => ({
    tba: tbaKey(e.key), frc: frcCode(e.first_event_code),
    name: String(e.name ?? e.key ?? "").slice(0, 200),
    start: day(e.start_date), end: day(e.end_date), tz: zone(e.timezone),
    location: place(e.city, e.state_prov, e.country), tier: tbaTier(e.event_type),
  })).filter((e) => e.tba && e.name);
}

// The same from FRC Events (no IANA time zone there), or null if it couldn't be read
async function fromFrc(team: number, season: number): Promise<Found[] | null> {
  const user = Deno.env.get("FRC_API_USER"), token = Deno.env.get("FRC_API_TOKEN");
  if (!user || !token) return null;
  const data = await getJson(`${FRC}/${season}/events?teamNumber=${team}`,
    { Authorization: "Basic " + btoa(`${user}:${token}`) }) as { Events?: Record<string, unknown>[] } | "missing" | null;
  if (data === "missing") return [];
  if (!data || typeof data !== "object" || !Array.isArray(data.Events)) return null;
  return data.Events.map((e) => ({
    tba: null, frc: frcCode(e.code), name: String(e.name ?? e.code ?? "").slice(0, 200),
    start: day(e.dateStart), end: day(e.dateEnd), tz: null,
    location: place(e.city, e.stateprov, e.country), tier: frcTier(e.type),
  })).filter((e) => e.frc && e.name);
}

// Blank dates on an events row, from the event's real first and last days. A row staff dated
// keeps its event_date; the real days are only kept when they agree with it (the table's checks).
function datesPatch(row: EventRow, start: string | null, end: string | null): Record<string, unknown> {
  const patch: Record<string, unknown> = {};
  const date = row.event_date ?? eventDate(start, end);
  if (!row.event_date && date) patch.event_date = date;
  if (!row.start_date && start && date && start <= date) patch.start_date = start;
  if (!row.end_date && end && date && end >= date) patch.end_date = end;
  return patch;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Use POST." }, 405);
  const secret = (Deno.env.get("SYNC_SECRET") ?? "").trim();
  if (!secret || (req.headers.get("x-sync-secret") ?? "").trim() !== secret) {
    return reply({ error: "Wrong or missing sync secret." }, 401);
  }
  let body: { team_number?: unknown };
  try { body = await req.json(); } catch { body = {}; }
  const one = Number(body.team_number);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const season = new Date().getUTCFullYear();
  const yearOf = (d: string | null) => d ? Number(d.slice(0, 4)) : null;

  const teamsQ = Number.isInteger(one) && one >= 1 && one <= 99999
    ? db.from("teams").select("team_number").eq("team_number", one)
    : db.from("teams").select("team_number");
  const [teamsR, eventsR] = await Promise.all([
    teamsQ,
    db.from("events").select("id,name,event_date,start_date,end_date,timezone,tba_event_key,frc_event_code,location"),
  ]);
  if (teamsR.error || eventsR.error) return reply({ error: (teamsR.error ?? eventsR.error)!.message }, 500);
  const events = eventsR.data as EventRow[];
  let added = 0, filled = 0;

  // The events row for one found event: matched on the TBA key, else the FRC code in the same
  // season. Blanks on a staff-made row are filled in; nothing staff set is changed.
  async function eventFor(f: Found): Promise<string | null> {
    let row = events.find((e) => f.tba && e.tba_event_key === f.tba) ??
      events.find((e) => f.frc && e.frc_event_code?.toUpperCase() === f.frc &&
        (yearOf(e.event_date) ?? season) === (yearOf(f.start) ?? season));
    if (!row) {
      const ok = !!(f.start && f.end && f.end >= f.start);
      const ins = await db.from("events").insert({
        name: f.name, location: f.location, event_date: eventDate(f.start, f.end),
        start_date: ok || !f.end ? f.start : null, end_date: ok ? f.end : null,
        timezone: f.tz, tba_event_key: f.tba, frc_event_code: f.frc, event_tier: f.tier, auto_added: true,
      }).select("id,name,event_date,start_date,end_date,timezone,tba_event_key,frc_event_code,location").single();
      if (ins.error) return null;
      events.push(ins.data as EventRow);
      added++;
      return (ins.data as EventRow).id;
    }
    const patch = datesPatch(row, f.start, f.end);
    if (!row.timezone && f.tz) patch.timezone = f.tz;
    if (!row.location && f.location) patch.location = f.location;
    if (!row.tba_event_key && f.tba && !events.some((e) => e.tba_event_key === f.tba)) patch.tba_event_key = f.tba;
    if (!row.frc_event_code && f.frc) patch.frc_event_code = f.frc;
    if (Object.keys(patch).length) {
      const up = await db.from("events").update(patch).eq("id", row.id);
      if (!up.error) { Object.assign(row, patch); filled++; }
    }
    return row.id;
  }

  const results: Record<string, unknown>[] = [];
  for (const { team_number: team } of teamsR.data as { team_number: number }[]) {
    const [tba, frc] = await Promise.all([fromTba(team, season), fromFrc(team, season)]);
    if (!tba && !frc) { results.push({ team, error: "TBA and FRC Events couldn't be read" }); continue; }
    // TBA first (it has time zones); FRC adds any event TBA doesn't list
    const found: (Found & { source: string })[] = (tba ?? []).map((f) => ({ ...f, source: "tba" }));
    for (const f of frc ?? []) {
      if (!found.some((x) => x.frc === f.frc)) found.push({ ...f, source: "frc" });
    }
    const rows: { event_id: string; team_number: number; source: string; updated_at: string }[] = [];
    for (const f of found) {
      const id = await eventFor(f);
      if (id && !rows.some((r) => r.event_id === id)) {
        rows.push({ event_id: id, team_number: team, source: f.source, updated_at: new Date().toISOString() });
      }
    }
    if (rows.length) {
      const up = await db.from("event_teams").upsert(rows, { onConflict: "event_id,team_number" });
      if (up.error) { results.push({ team, error: up.error.message }); continue; }
    }
    // A team that withdrew: only when both sources answered, so one being down removes nothing
    if (tba && frc) {
      const keep = new Set(rows.map((r) => r.event_id));
      const seasonIds = events.filter((e) => yearOf(e.event_date) === season && !keep.has(e.id)).map((e) => e.id);
      for (let i = 0; i < seasonIds.length; i += 100) {
        await db.from("event_teams").delete().eq("team_number", team).in("event_id", seasonIds.slice(i, i + 100));
      }
    }
    await db.from("teams").update({ events_synced_at: new Date().toISOString() }).eq("team_number", team);
    results.push({ team, events: rows.length });
  }

  // Dates and time zones for this season's linked events nobody's team goes to (every-team run only)
  const tbaKeyEnv = Deno.env.get("TBA_API_KEY");
  if (!one && tbaKeyEnv) {
    const todo = events.filter((e) => e.tba_event_key?.startsWith(String(season)) && (!e.start_date || !e.end_date || !e.timezone))
      .slice(0, FILL_LIMIT);
    for (const row of todo) {
      const e = await getJson(`${TBA}/event/${row.tba_event_key}`, { "X-TBA-Auth-Key": tbaKeyEnv }) as Record<string, unknown> | null;
      if (!e || typeof e !== "object") continue;
      const patch = datesPatch(row, day(e.start_date), day(e.end_date)), tz = zone(e.timezone);
      if (!row.timezone && tz) patch.timezone = tz;
      if (Object.keys(patch).length && !(await db.from("events").update(patch).eq("id", row.id)).error) filled++;
    }
  }

  const pick = await db.rpc("refresh_team_default_events");
  return reply({ result: "ok", season, teams: results, events_added: added, events_filled: filled,
                 defaults_changed: pick.error ? null : pick.data, defaults_error: pick.error?.message });
});
