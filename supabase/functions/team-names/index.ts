// team-names: looks up teams on The Blue Alliance and saves their nickname and logo in team_info
// (tba_name, tba_logo_url). The logo is the team's FIRST avatar for the season, which TBA serves
// as a small PNG; it's stored in the team-logos bucket under tba/ so pages load it like any logo.
// The 1307scout pages call this (through js/teams.js) with { teams: [1307, 254, ...] } whenever
// they show a team never looked up, or not looked up in 30 days.
//
// Deploy:  supabase functions deploy team-names --no-verify-jwt
// It uses the TBA_API_KEY secret that official-sync already has. "Verify JWT with legacy secret"
// stays off, as for the other functions: user tokens are ES256, so it checks the login itself.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const MAX_TEAMS = 60;     // per call; the pages send bigger lists in chunks
const RECHECK_DAYS = 30;  // names rarely change, and avatars change once a season
const TBA = "https://www.thebluealliance.com/api/v3";

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

// A TBA request: the parsed JSON, "missing" for a 404, or null if it failed (try another time)
async function tba(path: string, key: string): Promise<unknown> {
  try {
    const r = await fetch(TBA + path, { headers: { "X-TBA-Auth-Key": key } });
    if (r.status === 404) return "missing";
    if (!r.ok) return null;
    return await r.json();
  } catch {
    return null;
  }
}

// The team's avatar as PNG bytes: this season's, or last season's if it has none yet.
// "none" means TBA has no avatar; null means a request failed.
async function avatar(team: number, key: string): Promise<Uint8Array | "none" | null> {
  const year = new Date().getUTCFullYear();
  for (const y of [year, year - 1]) {
    const media = await tba(`/team/frc${team}/media/${y}`, key);
    if (media === null) return null;
    if (!Array.isArray(media)) continue;
    const found = media.find((m) => m?.type === "avatar" && m?.details?.base64Image);
    if (found) return Uint8Array.from(atob(found.details.base64Image), (c) => c.charCodeAt(0));
  }
  return "none";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply({ error: "Use POST." }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  // Team members only, checked with the caller's own token
  const asCaller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const level = await asCaller.rpc("my_access_level");
  if (level.error || (level.data !== "staff" && level.data !== "student")) {
    return reply({ error: "Team members only." }, 403);
  }

  const key = Deno.env.get("TBA_API_KEY");
  if (!key) return reply({ error: "The TBA_API_KEY secret isn't set." }, 500);

  let body: { teams?: unknown };
  try {
    body = await req.json();
  } catch {
    return reply({ error: "Send JSON like { teams: [1307] }." }, 400);
  }
  const asked = Array.isArray(body.teams) ? body.teams : [];
  const teams = [...new Set(asked.filter((t): t is number =>
    Number.isInteger(t) && (t as number) >= 1 && (t as number) <= 99999))].slice(0, MAX_TEAMS);
  if (!teams.length) return reply({ teams: {} });

  // Skip teams checked recently, so repeat calls don't reach TBA
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const since = new Date(Date.now() - RECHECK_DAYS * 864e5).toISOString();
  const recent = await admin.from("team_info").select("team_number")
    .in("team_number", teams).gte("tba_checked_at", since);
  if (recent.error) return reply({ error: recent.error.message }, 500);
  const done = new Set((recent.data ?? []).map((r: { team_number: number }) => r.team_number));
  const todo = teams.filter((t) => !done.has(t));

  const now = new Date().toISOString();
  const rows = (await Promise.all(todo.map(async (team) => {
    const info = await tba(`/team/frc${team}/simple`, key);
    if (info === null) return null;   // TBA didn't answer; leave it for another time
    const t = info as { nickname?: string; name?: string };
    // Every row carries the same columns, since a batch upsert blanks any a row leaves out.
    // If anything fails, the team is skipped and tried again next time, keeping what it had.
    const row: Record<string, unknown> = {
      team_number: team,
      tba_name: info === "missing" ? "" : String(t.nickname || t.name || "").trim().slice(0, 100),
      tba_logo_url: null,
      tba_checked_at: now,
    };
    const png = info === "missing" ? "none" : await avatar(team, key);
    if (png === null) return null;
    if (png !== "none") {
      const path = `tba/${team}.png`;
      const up = await admin.storage.from("team-logos").upload(path, png, { contentType: "image/png", upsert: true });
      if (up.error) return null;
      // The date in the address makes browsers fetch a replaced avatar
      row.tba_logo_url = admin.storage.from("team-logos").getPublicUrl(path).data.publicUrl + "?v=" + now.slice(0, 10);
    }
    return row;
  }))).filter((r): r is Record<string, unknown> => r !== null);

  if (rows.length) {
    // Sends only the TBA columns, so a name or logo staff set is left alone
    const saved = await admin.from("team_info").upsert(rows, { onConflict: "team_number" });
    if (saved.error) return reply({ error: saved.error.message }, 500);
  }
  const out: Record<number, { name: string; logo: string | null }> = {};
  rows.forEach((r) => {
    out[r.team_number as number] = { name: r.tba_name as string, logo: (r.tba_logo_url as string) ?? null };
  });
  return reply({ teams: out });
});
