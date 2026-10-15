-- The page is served by the n8n "3F Flips — Website" workflow straight from this table.
-- RLS on with no policies: only postgres/service_role can read or write it.
create table if not exists flips.site_files (
  name text primary key,
  content text not null,
  updated_at timestamptz not null default now()
);
alter table flips.site_files enable row level security;
revoke all on flips.site_files from public, anon, authenticated;
