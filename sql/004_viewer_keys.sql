-- Personal bookmark keys (same pattern as the Collections app's #k= links).
-- The sign-in email carries https://.../webhook/3f-flips#k=<key>; flips-login swaps the key for a fresh session.
-- RLS on, no policies: only the service role (edge function) and postgres (n8n) can read it.
create table if not exists flips.viewer_keys (
  email text primary key references flips.allowed_viewers(email) on delete cascade,
  key text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
alter table flips.viewer_keys enable row level security;
revoke all on flips.viewer_keys from public, anon, authenticated;
insert into flips.viewer_keys(email) select email from flips.allowed_viewers on conflict do nothing;
grant all on flips.viewer_keys, flips.site_files to service_role;
