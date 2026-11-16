// delete-account: the My Account "Delete account" button (account.html). Removes what the
// signed-in account entered (purge_member_data() and its photo files), then the account itself.
// The last staff member can't delete themselves. "Verify JWT" stays off: user tokens are
// ES256-signed, so the login is checked here instead.
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const url = Deno.env.get("SUPABASE_URL")!;
  const caller = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user } } = await caller.auth.getUser();
  if (!user) return json({ error: "Not signed in." }, 401);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: staffRow } = await admin.from("staff_members").select("user_id").eq("user_id", user.id).maybeSingle();
  if (staffRow) {
    const { count } = await admin.from("staff_members").select("user_id", { count: "exact", head: true });
    if ((count ?? 0) <= 1) {
      return json({ error: "You're the last staff member — set someone else as staff before deleting your account." }, 400);
    }
  }

  // Remove what this account entered first, so a failure stops here and can be retried.
  const { data: paths, error: purgeError } = await admin.rpc("purge_member_data", {
    target: user.id,
    p_reason: "deleted their own account",
  });
  if (purgeError) return json({ error: "Couldn't remove your data: " + purgeError.message }, 500);
  if (paths?.length) {
    const { error: photoError } = await admin.storage.from("scouting-photos").remove(paths);
    if (photoError) return json({ error: "Couldn't remove your photos: " + photoError.message }, 500);
  }

  const { error } = await admin.auth.admin.deleteUser(user.id);
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
});
