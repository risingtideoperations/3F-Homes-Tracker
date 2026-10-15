-- Write-side functions called by the n8n workflows (n8n connects as postgres).
-- None are callable from the browser.

-- Match key: house number + first street word, lowercased ("216 Oneal Dr" -> "216 oneal").
create or replace function flips.addr_key(a text) returns text
language sql immutable as $$
  select nullif(substring(lower(regexp_replace(coalesce(a,''), '\s+', ' ', 'g')) from '^\s*(\d+[a-z]?\s+[a-z0-9]+)'), '')
$$;

create or replace function flips.num(t text) returns numeric
language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return null; end if;
  return regexp_replace(t, '[$,\s]', '', 'g')::numeric;
exception when others then return null;
end $$;

create or replace function flips.dt(t text) returns date
language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return null; end if;
  return t::date;
exception when others then return null;
end $$;

-- Apply one of Rob's update emails.
-- p = {email_id, received_at, raw_text, parsed:{houses:[...]}|null, status, error}
-- Blank/null fields never overwrite stored values. Returns {ok, houses, status}.
create or replace function flips.apply_update(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  st text := coalesce(p->>'status', 'parsed');
  h jsonb; hid bigint; n int := 0; ids bigint[] := '{}'; first_note text;
  stg text;
begin
  if exists (select 1 from flips.updates where source_email_id = p->>'email_id') then
    return jsonb_build_object('ok', true, 'skipped', 'already processed');
  end if;

  if st in ('parsed','parsed_ai') and jsonb_typeof(p->'parsed'->'houses') = 'array' then
    begin
      for h in select * from jsonb_array_elements(p->'parsed'->'houses') loop
        if nullif(btrim(h->>'address'), '') is null then continue; end if;
        stg := case when h->>'stage' in ('Under Contract','Closed','Renovating','Listed','Sale Pending','Sold')
                    then h->>'stage' end;
        select id into hid from flips.houses where lower(address) = lower(btrim(h->>'address'));
        if hid is null then
          insert into flips.houses(address, stage) values (btrim(h->>'address'), coalesce(stg, 'Under Contract'))
          returning id into hid;
        end if;
        update flips.houses set
          stage                  = coalesce(stg, stage),
          purchase_price         = coalesce(flips.num(h->>'purchase_price'), purchase_price),
          purchase_close_date    = coalesce(flips.dt(h->>'purchase_close_date'), purchase_close_date),
          loan_amount            = coalesce(flips.num(h->>'loan_amount'), loan_amount),
          lender                 = coalesce(nullif(btrim(h->>'lender'), ''), lender),
          earnest_money_paid     = coalesce(flips.num(h->>'earnest_money_paid'), earnest_money_paid),
          est_buy_closing_costs  = coalesce(flips.num(h->>'est_buy_closing_costs'), est_buy_closing_costs),
          cash_to_close          = coalesce(flips.num(h->>'cash_to_close'), cash_to_close),
          funded                 = coalesce((case when h->>'funded' in ('true','false') then (h->>'funded')::boolean end), funded),
          reno_scope             = coalesce(flips.num(h->>'reno_scope'), reno_scope),
          reno_start_date        = coalesce(flips.dt(h->>'reno_start_date'), reno_start_date),
          reno_end_date          = coalesce(flips.dt(h->>'reno_end_date'), reno_end_date),
          target_sale_price      = coalesce(flips.num(h->>'target_sale_price'), target_sale_price),
          list_date              = coalesce(flips.dt(h->>'list_date'), list_date),
          sale_contract_date     = coalesce(flips.dt(h->>'sale_contract_date'), sale_contract_date),
          sale_close_date        = coalesce(flips.dt(h->>'sale_close_date'), sale_close_date),
          sale_price             = coalesce(flips.num(h->>'sale_price'), sale_price),
          loan_payoff            = coalesce(flips.num(h->>'loan_payoff'), loan_payoff),
          est_sell_closing_costs = coalesce(flips.num(h->>'est_sell_closing_costs'), est_sell_closing_costs),
          other_costs            = coalesce(flips.num(h->>'other_costs'), other_costs),
          notes                  = coalesce(nullif(btrim(h->>'note'), ''), notes),
          updated_at             = now()
        where id = hid;
        n := n + 1; ids := ids || hid;
        first_note := coalesce(first_note, nullif(btrim(h->>'note'), ''));
      end loop;
    exception when others then
      insert into flips.updates(source_email_id, received_at, raw_text, parsed, note, status)
      values (p->>'email_id', coalesce((p->>'received_at')::timestamptz, now()), p->>'raw_text', p->'parsed',
              'Error: ' || sqlerrm, 'error');
      return jsonb_build_object('ok', false, 'status', 'error', 'error', sqlerrm);
    end;
    if n = 0 then st := 'unparsed'; end if;
    perform flips.apply_splits(p);
  elsif st not in ('error') then
    st := 'unparsed';
  end if;

  insert into flips.updates(house_id, source_email_id, received_at, raw_text, parsed, note, status)
  values (case when array_length(ids,1) = 1 then ids[1] end, p->>'email_id',
          coalesce((p->>'received_at')::timestamptz, now()), p->>'raw_text', p->'parsed',
          coalesce(first_note, p->>'error'), st);
  perform flips.rematch_costs();
  return jsonb_build_object('ok', st in ('parsed','parsed_ai'), 'status', st, 'houses', n);
end $$;

-- Attach unmatched QuickBooks costs to a house when exactly one house has the same address key.
create or replace function flips.rematch_costs() returns int
language plpgsql security definer set search_path = '' as $$
declare k int;
begin
  with keys as (
    select flips.addr_key(address) k, min(id) id, count(*) c from flips.houses group by 1
  )
  update flips.costs c set house_id = keys.id, updated_at = now()
  from keys
  where c.house_id is null and c.source = 'quickbooks' and keys.c = 1
    and keys.k = flips.addr_key(c.qb_customer);
  get diagnostics k = row_count;
  return k;
end $$;

-- Upsert QuickBooks cost rows. rows = [{qb_txn_id, qb_doc_type, qb_customer, txn_date, vendor, memo, amount}]
-- Returns matched/unmatched counts plus the unmatched customers.
create or replace function flips.upsert_qb_costs(rows jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into flips.costs(source, qb_txn_id, qb_doc_type, qb_customer, txn_date, vendor, memo, amount)
  select 'quickbooks', r->>'qb_txn_id', r->>'qb_doc_type', r->>'qb_customer', flips.dt(r->>'txn_date'),
         r->>'vendor', r->>'memo', coalesce(flips.num(r->>'amount'), 0)
  from jsonb_array_elements(coalesce(rows, '[]'::jsonb)) r
  where nullif(r->>'qb_txn_id','') is not null
  on conflict (qb_txn_id) do update set
    qb_doc_type = excluded.qb_doc_type, qb_customer = excluded.qb_customer, txn_date = excluded.txn_date,
    vendor = excluded.vendor, memo = excluded.memo, amount = excluded.amount, updated_at = now();
  get diagnostics n = row_count;
  -- An edited invoice can lose lines: drop stored lines of the touched invoices that are gone now.
  delete from flips.costs c
  where c.source = 'quickbooks'
    and split_part(c.qb_txn_id, '-', 1) in (select distinct split_part(r->>'qb_txn_id', '-', 1)
                                            from jsonb_array_elements(coalesce(rows, '[]'::jsonb)) r)
    and c.qb_txn_id not in (select r->>'qb_txn_id' from jsonb_array_elements(coalesce(rows, '[]'::jsonb)) r);
  perform flips.rematch_costs();
  return jsonb_build_object(
    'upserted', n,
    'unmatched', (select coalesce(jsonb_agg(distinct qb_customer), '[]') from flips.costs
                  where source = 'quickbooks' and house_id is null));
end $$;

-- One snapshot row per house per refresh (feeds "change since last update").
create or replace function flips.take_snapshot() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into flips.snapshots(house_id, projected_profit)
  select id, profit from flips.house_calc;
  get diagnostics n = row_count;
  insert into flips.sync_state(key, value, updated_at) values ('last_snapshot', now()::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return n;
end $$;

-- Houses that need the one-time "closing in <=7 days and not funded" email.
create or replace function flips.funding_alerts_due() returns table(id bigint, address text, purchase_close_date date, cash_to_close numeric, days_out int)
language sql security definer set search_path = '' as $$
  select d.id, d.address, d.purchase_close_date, d.cash_to_close, d.days_to_purchase_close
  from flips.dashboard d join flips.houses h on h.id = d.id
  where d.stage = 'Under Contract' and not d.funded and h.funding_alert_sent_at is null
    and d.days_to_purchase_close between 0 and 7
$$;

create or replace function flips.mark_funding_alert(hid bigint) returns void
language sql security definer set search_path = '' as $$
  update flips.houses set funding_alert_sent_at = now() where id = hid
$$;

-- Browser roles can't run any of these.
revoke execute on function flips.apply_update(jsonb), flips.rematch_costs(), flips.upsert_qb_costs(jsonb),
  flips.take_snapshot(), flips.funding_alerts_due(), flips.mark_funding_alert(bigint)
  from public, anon, authenticated;
