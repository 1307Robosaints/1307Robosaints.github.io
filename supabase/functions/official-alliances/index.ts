// official-alliances: copies an event's playoff alliances from the FRC Events API (or The Blue
// Alliance if FRC has none) into playoff_picks, so Playoff Selection and the Playoff Bracket follow
// the official alliances. official_sync_request() in SQL/rebuild_all.sql calls it next to
// official-sync, so auto-sync and the Resync data button both refresh the alliances.
//
// Request: POST { event_id } with the x-sync-secret header (same secret as official-sync).
// The database side is official_set_alliances(), which only applies a finished selection and
// writes nothing when the picks already match.
//
// Deploy:  supabase functions deploy official-alliances --no-verify-jwt
// It uses secrets official-sync already has: FRC_API_USER, FRC_API_TOKEN, TBA_API_KEY, SYNC_SECRET.
import { createClient } from "npm:@supabase/supabase-js@2";

const FRC = "https://frc-api.firstinspires.org/v3.0";
const TBA = "https://www.thebluealliance.com/api/v3";

type Alliance = { number: number; teams: number[] };

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

// Team numbers in pick order, without blanks
function cleanTeams(list: unknown[]): number[] {
  return list.map((t) => Number(String(t ?? "").replace(/^frc/, "")))
    .filter((t) => Number.isInteger(t) && t >= 1 && t <= 99999);
}

// FRC Events: { Alliances: [{ number, captain, round1, round2, round3, backup }] }
async function fromFrc(season: number, code: string): Promise<Alliance[] | null> {
  const user = Deno.env.get("FRC_API_USER"), token = Deno.env.get("FRC_API_TOKEN");
  if (!user || !token) return null;
  const data = await getJson(`${FRC}/${season}/alliances/${encodeURIComponent(code)}`,
    { Authorization: "Basic " + btoa(`${user}:${token}`) }) as { Alliances?: Record<string, unknown>[] } | null;
  if (!data || typeof data !== "object" || !Array.isArray(data.Alliances)) return null;
  return data.Alliances.map((a) => ({
    number: Number(a.number),
    teams: cleanTeams([a.captain, a.round1, a.round2, a.round3]),
  })).filter((a) => a.number >= 1 && a.number <= 8 && a.teams.length);
}

// TBA: [{ picks: ["frc1307", ...] }, ...], in alliance order (backups aren't picks)
async function fromTba(key: string): Promise<Alliance[] | null> {
  const apiKey = Deno.env.get("TBA_API_KEY");
  if (!apiKey) return null;
  const data = await getJson(`${TBA}/event/${encodeURIComponent(key)}/alliances`, { "X-TBA-Auth-Key": apiKey });
  if (!Array.isArray(data)) return null;
  return data.slice(0, 8).map((a: { picks?: unknown[] }, i: number) => ({
    number: i + 1,
    teams: cleanTeams(a?.picks ?? []).slice(0, 4),
  })).filter((a) => a.teams.length);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Use POST." }, 405);
  const secret = (Deno.env.get("SYNC_SECRET") ?? "").trim();
  if (!secret || (req.headers.get("x-sync-secret") ?? "").trim() !== secret) {
    return reply({ error: "Wrong or missing sync secret." }, 401);
  }

  let body: { event_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return reply({ error: "Send JSON like { event_id }." }, 400);
  }
  if (typeof body.event_id !== "string") return reply({ error: "event_id is required." }, 400);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const ev = await db.from("events").select("id,frc_event_code,tba_event_key,event_date")
    .eq("id", body.event_id).maybeSingle();
  if (ev.error) return reply({ error: ev.error.message }, 500);
  if (!ev.data) return reply({ error: "No such event." }, 404);

  // The season is the event's year, or the year in its TBA key (2026nhalt1)
  const season = Number(String(ev.data.tba_event_key ?? "").slice(0, 4)) ||
    (ev.data.event_date ? new Date(ev.data.event_date).getUTCFullYear() : new Date().getUTCFullYear());

  let alliances: Alliance[] | null = null, source = "";
  if (ev.data.frc_event_code) {
    alliances = await fromFrc(season, ev.data.frc_event_code);
    source = "frc";
  }
  if ((!alliances || !alliances.length) && ev.data.tba_event_key) {
    alliances = await fromTba(ev.data.tba_event_key);
    source = "tba";
  }
  if (!alliances || !alliances.length) return reply({ result: "none" });

  const r = await db.rpc("official_set_alliances", { p_event: ev.data.id, p_alliances: alliances });
  if (r.error) return reply({ error: r.error.message }, 500);
  return reply({ result: r.data, source, alliances: alliances.length });
});
