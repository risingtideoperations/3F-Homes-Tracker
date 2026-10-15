-- Ryan's Claude gets its own agent key; direct updates are logged with the agent's name.
insert into flips.agent_keys(name) values ('Ryan''s Claude (rmedo@rtmhouses.com)') on conflict do nothing;

create or replace function flips.agent_update(k text, body jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare who text; r jsonb;
begin
  select name into who from flips.agent_keys where key = k;
  if who is null then return jsonb_build_object('error','invalid key'); end if;
  if jsonb_typeof(body->'houses') <> 'array' then return jsonb_build_object('error','body must be {"houses":[...]}'); end if;
  update flips.agent_keys set last_used_at = now() where key = k;
  r := flips.apply_update(jsonb_build_object(
        'email_id', 'api-' || lower(regexp_replace(split_part(who, ' ', 1), '[^A-Za-z]', '', 'g')) || '-' || to_char(clock_timestamp(),'YYYYMMDD-HH24MISS-US'),
        'received_at', now(), 'raw_text', 'Direct update by ' || who || E'\n' || left(body::text, 20000), 'parsed', body, 'status', 'parsed'));
  return jsonb_build_object('result', r, 'updated_by', who, 'feed', flips.agent_feed(k));
end $$;
revoke execute on function flips.agent_update(text, jsonb) from public, anon, authenticated;
