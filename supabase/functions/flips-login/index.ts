// flips-login: sign-in for the 3 allowlisted viewers of the 3F Flip Tracker.
//   POST {email} -> if allowlisted, n8n ("3F Flips — Website") emails that person their
//                   personal bookmark link  .../webhook/3f-flips#k=<key>  (always answers ok).
//   POST {key}   -> swaps a valid bookmark key for a one-time token_hash; the page calls
//                   auth.verifyOtp() with it. Same #k= pattern as the Collections app, so a
//                   bookmark keeps working even inside n8n's sandboxed page (no localStorage).
// No project auth settings or Supabase mailer are used.
import { createClient } from "jsr:@supabase/supabase-js@2";

const MAILER = "https://risingtideoperations.app.n8n.cloud/webhook/3f-flips-mail";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "content-type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let body: { email?: string; key?: string } = {};
  try { body = await req.json(); } catch { /* bad body */ }

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const keys = db.schema("flips").from("viewer_keys");

  // Bookmark key -> session token
  const key = String(body.key || "").trim();
  if (key) {
    if (!/^[a-f0-9]{48}$/.test(key)) return json({ error: "Invalid link" }, 401);
    const { data: row } = await keys.select("email").eq("key", key).maybeSingle();
    if (!row) return json({ error: "This link is no longer valid. Ask for a new one." }, 401);
    await db.auth.admin.createUser({ email: row.email, email_confirm: true }).catch(() => {});
    const { data, error } = await db.auth.admin.generateLink({ type: "magiclink", email: row.email });
    if (error || !data?.properties?.hashed_token) return json({ error: "Could not sign in" }, 500);
    await keys.update({ last_used_at: new Date().toISOString() }).eq("key", key);
    return json({ token_hash: data.properties.hashed_token });
  }

  // Email -> send the bookmark link
  const email = String(body.email || "").trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Enter an email" }, 400);
  const { data: row } = await keys.select("key").eq("email", email).maybeSingle();
  // Same answer either way so the page doesn't reveal who is on the list.
  if (!row) return json({ ok: true });
  const r = await fetch(MAILER, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, key: row.key }),
  }).catch(() => null);
  if (!r || !r.ok) return json({ error: "Email failed, try again" }, 502);
  return json({ ok: true });
});
