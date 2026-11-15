// manage-member: the Staff Portal's ban / unban / delete buttons (portal.html, Members tab).
// Deployed under the slug bright-responder (see supabase/config.toml), which is the name
// portal.html invokes. Staff only; can't act on yourself or on a staff account. Ban and delete
// first remove what the account entered through purge_member_data(), then its photo files.
// "Verify JWT" stays off: user tokens are ES256-signed, so the login is checked here instead.
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

  const { data: isStaff } = await caller.rpc("is_staff");
  if (!isStaff) return json({ error: "Staff only." }, 403);

  const { action, target } = await req.json().catch(() => ({}));
  if (!["ban", "unban", "delete"].includes(action) || !target) return json({ error: "Bad request." }, 400);
  if (target === user.id) return json({ error: "You can't " + action + " your own account." }, 400);

  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { autoRefreshToken: false, persistSession: false },
  });

  const { data: staffRow } = await admin.from("staff_members").select("user_id").eq("user_id", target).maybeSingle();
  if (staffRow) {
    return json({ error: "Remove staff access before " + (action === "delete" ? "deleting" : "banning") + " this account." }, 400);
  }

  // Ban and delete both remove what the account entered. This runs first so a failure
  // stops here and the action can simply be retried.
  if (action !== "unban") {
    const verb = action === "ban" ? "banned" : "deleted";
    const { data: paths, error: purgeError } = await admin.rpc("purge_member_data", {
      target,
      p_reason: verb + " by " + user.email,
    });
    if (purgeError) return json({ error: "Couldn't remove this account's data: " + purgeError.message }, 500);
    if (paths?.length) {
      const { error: photoError } = await admin.storage.from("scouting-photos").remove(paths);
      if (photoError) return json({ error: "Couldn't remove this account's photos: " + photoError.message }, 500);
    }
  }

  if (action === "delete") {
    const { error } = await admin.auth.admin.deleteUser(target);
    if (error) return json({ error: error.message }, 500);
    return json({ ok: true });
  }

  const { error } = await admin.auth.admin.updateUserById(target, {
    ban_duration: action === "ban" ? "876000h" : "none",
  });
  if (error) return json({ error: error.message }, 500);

  if (action === "ban") await caller.rpc("staff_kick", { target });
  return json({ ok: true });
});
