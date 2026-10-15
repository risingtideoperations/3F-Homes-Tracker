// flips-login: emails a one-time sign-in link to the 3 allowlisted viewers.
// Supabase's built-in mailer only reaches org members, so the link is generated
// with the admin API and emailed by the n8n "3F Flips — Website" workflow (ops Gmail).
// n8n re-checks the allowlist and builds the link itself, so its webhook needs no secret.
// The link carries a token_hash; the page calls auth.verifyOtp() itself, so no
// redirect-URL change to the project's auth settings is needed.
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
  let email = "";
  try { email = String((await req.json()).email || "").trim().toLowerCase(); } catch { /* bad body */ }
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return json({ error: "Enter an email" }, 400);

  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
  const { data: ok } = await db.schema("flips").from("allowed_viewers").select("email").eq("email", email).maybeSingle();
  // Same answer either way so the page doesn't reveal who is on the list.
  if (!ok) return json({ ok: true });

  // Make sure the user exists (no-op if already there), then mint the link.
  await db.auth.admin.createUser({ email, email_confirm: true }).catch(() => {});
  const { data, error } = await db.auth.admin.generateLink({ type: "magiclink", email });
  if (error || !data?.properties?.hashed_token) return json({ error: "Could not create link" }, 500);
  const r = await fetch(MAILER, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, token_hash: data.properties.hashed_token }),
  }).catch(() => null);
  if (!r || !r.ok) return json({ error: "Email failed, try again" }, 502);
  return json({ ok: true });
});
