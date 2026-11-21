// social-feed: collects the homepage's Recent Posts (the team's own social media) and FRC News
// (FIRST's blog and the FRC YouTube channel) into social_posts (section 8t of rebuild_all.sql).
// index.html reads them through public_social_feed(); visitors never call this function.
// pg_cron runs it every 30 minutes through social_feed_request(), with the x-sync-secret header.
//
// Sources, each one optional: a source that fails keeps the posts it saved last time.
//   YouTube       public channel feeds, no key. The channel ID is read from the @handle page,
//                 or set it with the YT_CHANNEL_TEAM / YT_CHANNEL_FRC secrets if that stops working.
//   FIRST blog    the public RSS feed, FRC posts only.
//   Instagram     needs a token: a row ('instagram', '<token>') in social_tokens (Instagram API with
//                 Instagram Login, professional account). Refreshed here weekly, so it never lapses.
//   Facebook      needs a non-expiring Page access token: a row ('facebook', '<token>') in social_tokens.
//   TikTok        has no public feed (its API needs app review), so the homepage only links to it.
//
// Deploy:  supabase functions deploy social-feed --use-api   (JWT verification off, in config.toml)
// It uses the SYNC_SECRET secret that official-sync already has.
import { createClient } from "npm:@supabase/supabase-js@2";
import { XMLParser } from "npm:fast-xml-parser@4.5.0";

const TEAM_YOUTUBE = "@1307Robosaints";
const FRC_YOUTUBE = "@FIRSTRoboticsCompetition";
const FIRST_BLOG_RSS = "https://www.firstinspires.org/community-blog/rss.xml";
const KEEP = 6;                       // posts kept per source; the page shows fewer
const TOKEN_REFRESH_DAYS = 7;         // Instagram tokens last 60 days
const UA = { "User-Agent": "Mozilla/5.0 (compatible; social-feed/1.0)", "Accept-Language": "en-US,en" };

type Post = {
  feed: "team" | "frc"; source: string; post_id: string; title: string | null; body: string | null;
  url: string; image_url: string | null; posted_at: string;
};

const xml = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: "@", processEntities: true });

function reply(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

async function get(url: string, kind: "text" | "json" = "text"): Promise<any> {
  const r = await fetch(url, { headers: UA, signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error(`${r.status} from ${new URL(url).host}`);
  return kind === "json" ? r.json() : r.text();
}

const arr = (v: unknown): any[] => (v == null ? [] : Array.isArray(v) ? v : [v]);
const text = (v: any): string => (v == null ? "" : typeof v === "object" ? String(v["#text"] ?? "") : String(v));

// HTML (a blog post, a caption) to a short plain-text excerpt
function plain(html: string, max = 220): string {
  const s = html.replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ").replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#39;|&rsquo;|&lsquo;/g, "'")
    .replace(/&ldquo;|&rdquo;/g, '"').replace(/&mdash;/g, "—").replace(/&ndash;/g, "–").replace(/&hellip;/g, "…")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n))
    .replace(/&#x([0-9a-f]+);/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)))
    .replace(/\s+/g, " ").trim();
  return s.length > max ? s.slice(0, max).replace(/\s+\S*$/, "") + "…" : s;
}

async function channelId(handle: string, override?: string): Promise<string> {
  if (override) return override;
  const page = await get(`https://www.youtube.com/${handle}`);
  const m = page.match(/<link rel="canonical" href="https:\/\/www\.youtube\.com\/channel\/(UC[\w-]{22})"/) ||
            page.match(/"externalId":"(UC[\w-]{22})"/);
  if (!m) throw new Error(`no channel ID on the ${handle} page`);
  return m[1];
}

async function youtube(feed: Post["feed"], source: string, handle: string, override?: string): Promise<Post[]> {
  const id = await channelId(handle, override);
  const doc = xml.parse(await get(`https://www.youtube.com/feeds/videos.xml?channel_id=${id}`));
  return arr(doc?.feed?.entry).slice(0, KEEP).map((e) => {
    const vid = text(e["yt:videoId"]);
    const link = arr(e.link).find((l) => l["@rel"] === "alternate") ?? arr(e.link)[0];
    return {
      feed, source, post_id: vid, title: text(e.title) || null,
      body: plain(text(e["media:group"]?.["media:description"])) || null,
      url: link?.["@href"] || `https://www.youtube.com/watch?v=${vid}`,
      image_url: `https://i.ytimg.com/vi/${vid}/hqdefault.jpg`,
      posted_at: new Date(text(e.published)).toISOString(),
    };
  });
}

async function firstBlog(): Promise<Post[]> {
  const doc = xml.parse(await get(FIRST_BLOG_RSS));
  return arr(doc?.rss?.channel?.item)
    .filter((i) => arr(i.category).some((c) => /\bfrc\b|robotics competition/i.test(text(c))))
    .slice(0, KEEP)
    .map((i) => {
      // description starts with the featured image, then the post; content:encoded is the post alone
      const html = text(i.description) || text(i["content:encoded"]);
      // The featured picture: the first real image, not HubSpot's tracking pixel
      const img = [...html.matchAll(/<img[^>]+src="([^"]+)"/gi)].map((m) => m[1].replace(/&amp;/g, "&"))
        .find((src) => /^https:\/\//.test(src) && !/track\.hubspot|__ptq\.gif|pixel/i.test(src));
      const url = text(i.link);
      return {
        feed: "frc" as const, source: "first_blog", post_id: text(i.guid) || url, title: text(i.title) || null,
        body: plain(html) || null, url, image_url: img ?? null,
        posted_at: new Date(text(i.pubDate)).toISOString(),
      };
    });
}

async function instagram(token: string): Promise<Post[]> {
  const fields = "id,caption,media_type,media_url,thumbnail_url,permalink,timestamp";
  const r = await get(`https://graph.instagram.com/me/media?fields=${fields}&limit=${KEEP}&access_token=${encodeURIComponent(token)}`, "json");
  return arr(r?.data).map((m) => ({
    feed: "team" as const, source: "instagram", post_id: String(m.id), title: null,
    body: m.caption ? plain(m.caption) : null, url: m.permalink,
    image_url: m.media_type === "VIDEO" ? m.thumbnail_url ?? null : m.media_url ?? null,
    posted_at: new Date(m.timestamp).toISOString(),
  }));
}

async function facebook(token: string): Promise<Post[]> {
  const fields = "id,message,permalink_url,full_picture,created_time";
  const r = await get(`https://graph.facebook.com/v21.0/me/posts?fields=${fields}&limit=${KEEP}&access_token=${encodeURIComponent(token)}`, "json");
  return arr(r?.data).filter((p) => p.permalink_url).map((p) => ({
    feed: "team" as const, source: "facebook", post_id: String(p.id), title: null,
    body: p.message ? plain(p.message) : null, url: p.permalink_url, image_url: p.full_picture ?? null,
    posted_at: new Date(p.created_time).toISOString(),
  }));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply({ error: "Use POST." }, 405);
  const secret = (Deno.env.get("SYNC_SECRET") ?? "").trim();
  if (!secret || (req.headers.get("x-sync-secret") ?? "").trim() !== secret) {
    return reply({ error: "Wrong or missing sync secret." }, 401);
  }
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

  // Tokens for the networks that need one; Instagram's is refreshed here before it can expire
  const tokens: Record<string, string> = {};
  const t = await db.from("social_tokens").select("network, token, refreshed_at");
  for (const row of t.data ?? []) {
    if (!row.token) continue;
    tokens[row.network] = row.token;
    if (row.network === "instagram" && new Date(row.refreshed_at).getTime() < Date.now() - TOKEN_REFRESH_DAYS * 864e5) {
      try {
        const r = await get(`https://graph.instagram.com/refresh_access_token?grant_type=ig_refresh_token&access_token=${encodeURIComponent(row.token)}`, "json");
        if (r?.access_token) {
          tokens.instagram = r.access_token;
          await db.from("social_tokens").update({ token: r.access_token, refreshed_at: new Date().toISOString() })
            .eq("network", "instagram");
        }
      } catch { /* the old token still works until it expires; try again next run */ }
    }
  }

  const jobs: Record<string, () => Promise<Post[]>> = {
    team_youtube: () => youtube("team", "team_youtube", TEAM_YOUTUBE, Deno.env.get("YT_CHANNEL_TEAM")),
    frc_youtube: () => youtube("frc", "frc_youtube", FRC_YOUTUBE, Deno.env.get("YT_CHANNEL_FRC")),
    first_blog: firstBlog,
  };
  if (tokens.instagram) jobs.instagram = () => instagram(tokens.instagram);
  if (tokens.facebook) jobs.facebook = () => facebook(tokens.facebook);

  const result: Record<string, number | string> = {};
  await Promise.all(Object.entries(jobs).map(async ([source, job]) => {
    try {
      const posts = (await job()).filter((p) => p.post_id && p.url && !isNaN(Date.parse(p.posted_at)));
      if (!posts.length) throw new Error("no posts in the feed");
      const now = new Date().toISOString();
      const up = await db.from("social_posts").upsert(posts.map((p) => ({ ...p, fetched_at: now })),
        { onConflict: "source,post_id" });
      if (up.error) throw new Error(up.error.message);
      // Drop posts that fell off the feed (or were deleted)
      const ids = posts.map((p) => `"${p.post_id.replace(/"/g, '\\"')}"`).join(",");
      await db.from("social_posts").delete().eq("source", source).not("post_id", "in", `(${ids})`);
      result[source] = posts.length;
    } catch (e) {
      result[source] = `failed: ${(e as Error).message}`;
    }
  }));
  return reply(result);
});

// For a local check of the parsers against the live feeds
export { firstBlog, youtube };
