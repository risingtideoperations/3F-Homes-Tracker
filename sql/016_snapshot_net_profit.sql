-- Snapshots stored profit before partner shares, but the page compares them to real profit
-- (after shares), so every house showed a fake drop. Snapshot the real profit instead and
-- drop the old pre-share rows.
create or replace function flips.take_snapshot() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into flips.snapshots(house_id, projected_profit)
  select id, profit from flips.dashboard;
  get diagnostics n = row_count;
  insert into flips.sync_state(key, value, updated_at) values ('last_snapshot', now()::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return n;
end $$;
revoke execute on function flips.take_snapshot() from public, anon, authenticated;

delete from flips.snapshots;
select flips.take_snapshot();
