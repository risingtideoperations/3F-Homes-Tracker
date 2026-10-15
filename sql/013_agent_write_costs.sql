-- Rob's Claude: direct write API + itemized costs; gross profit after commissions.
alter table flips.costs drop constraint if exists costs_source_check;
alter table flips.costs add constraint costs_source_check check (source in ('quickbooks','manual','rob'));
alter table flips.costs add column if not exists category text;  -- for source 'rob': reno | closing_buy | closing_sell | holding | other

create or replace view flips.house_calc with (security_invoker = true) as
with spent as (
  select house_id, sum(amount) reno_spent from flips.costs
  where house_id is not null and (source = 'quickbooks' or category = 'reno') group by house_id
), base as (
  select h.*,
    coalesce(s.reno_spent,0) as reno_spent,
    coalesce(h.cash_to_close,
      coalesce(h.purchase_price,0) + coalesce(h.est_buy_closing_costs,0)
      - case when h.lender ilike 'rising tide%' then 0 else coalesce(h.loan_amount,0) end
      - coalesce(h.earnest_money_paid,0)) as cash_to_close_calc,
    (h.cash_to_close is not null) as cash_to_close_exact,
    coalesce(h.sale_price, h.target_sale_price) as sale_price_used
  from flips.houses h left join spent s on s.house_id = h.id
), g as (
  select b.*,
    coalesce(b.earnest_money_paid,0)
      + case when b.stage <> 'Under Contract' then b.cash_to_close_calc else 0 end
      + b.reno_spent + coalesce(b.other_costs,0) as total_cash_in,
    greatest(coalesce(b.reno_scope,0) - b.reno_spent, 0) as reno_remaining,
    case when coalesce(b.reno_scope,0) > 0 then round(b.reno_spent / b.reno_scope * 100, 1) end as reno_pct,
    -- all-in cost to date vs. the planned budget
    coalesce(b.purchase_price,0) + coalesce(b.est_buy_closing_costs,0) + b.reno_spent + coalesce(b.other_costs,0) as all_in_cost,
    coalesce(b.purchase_price,0) + coalesce(b.est_buy_closing_costs,0) + coalesce(b.reno_scope,0) + coalesce(b.other_costs,0) as total_budget,
    -- gross profit: projected counts the larger of scope and spent; sold uses actual spent
    b.sale_price_used
      - coalesce(b.purchase_price,0)
      -- as-is phase (owned, before a rehab is committed): only money actually spent; rehab scope counts once renovating
      - case when b.stage = 'Sold' or b.stage in ('Closed','Make-Ready','Listed As-Is') then b.reno_spent
             else greatest(b.reno_spent, coalesce(b.reno_scope,0)) end
      - coalesce(b.other_costs,0)
      - coalesce(b.est_buy_closing_costs,0)
      - coalesce(b.est_sell_closing_costs,0) as profit,
    coalesce(b.sale_price, b.target_sale_price)
      - case when b.lender ilike 'rising tide%' then 0 else coalesce(b.loan_payoff, b.loan_amount, 0) end
      - coalesce(b.est_sell_closing_costs,0) as est_net_proceeds,
    array_position(array['Under Contract','Closed','Make-Ready','Listed As-Is','Renovating','Listed','Sale Pending','Sold'], b.stage) as stage_no
  from base b
), s as (
  select g.*,
    coalesce((select sum(flips.num(x->>'amount')) from jsonb_array_elements(coalesce(g.sale_splits,'[]')) x where x->>'basis' = 'fixed'),0) as split_fixed,
    coalesce((select sum(flips.num(x->>'pct')) from jsonb_array_elements(coalesce(g.sale_splits,'[]')) x where x->>'basis' = 'sale'),0) / 100.0 * coalesce(g.sale_price_used,0) as split_sale,
    coalesce((select sum(flips.num(x->>'pct')) from jsonb_array_elements(coalesce(g.sale_splits,'[]')) x where x->>'basis' = 'profit'),0) / 100.0 as split_profit_pct
  from g
)
select s.*,
  s.profit - s.split_fixed - s.split_sale as profit_before_shares,
  case when s.profit - s.split_fixed - s.split_sale > 0 then round((s.profit - s.split_fixed - s.split_sale) * s.split_profit_pct, 2) else 0 end as split_profit,
  s.profit - s.split_fixed - s.split_sale
    - case when s.profit - s.split_fixed - s.split_sale > 0 then round((s.profit - s.split_fixed - s.split_sale) * s.split_profit_pct, 2) else 0 end as net_profit,
  (s.sale_splits is not null) as splits_known,
  -- each split line with its dollar amount
  (select coalesce(jsonb_agg(x || jsonb_build_object('dollars',
      case x->>'basis'
        when 'fixed'  then coalesce(flips.num(x->>'amount'),0)
        when 'sale'   then round(coalesce(flips.num(x->>'pct'),0) / 100.0 * coalesce(s.sale_price_used,0), 2)
        when 'profit' then case when s.profit - s.split_fixed - s.split_sale > 0
                           then round(coalesce(flips.num(x->>'pct'),0) / 100.0 * (s.profit - s.split_fixed - s.split_sale), 2) else 0 end
      end)), '[]'::jsonb)
   from jsonb_array_elements(coalesce(s.sale_splits,'[]')) x) as splits_detail
from s;




drop view if exists flips.dashboard cascade;
create view flips.dashboard with (security_invoker = true) as
select c.id, c.address, c.stage, c.stage_no,
  case when c.stage = 'Under Contract' then 'Under contract'
       when c.stage in ('Closed','Make-Ready','Listed As-Is') then 'Owned: make-ready + as-is'
       when c.stage = 'Renovating' then 'In renovation'
       when c.stage = 'Listed' then 'Listed after reno'
       when c.stage = 'Sale Pending' then 'Sale pending'
       else 'Sold' end as stage_group,
  c.purchase_price, c.purchase_close_date, c.loan_amount, c.lender, c.earnest_money_paid,
  c.est_buy_closing_costs, c.cash_to_close_calc as cash_to_close, c.cash_to_close_exact, c.funded,
  (c.purchase_close_date - current_date) as days_to_purchase_close,
  case when c.stage = 'Under Contract' and coalesce(c.funded, false) = false and c.purchase_close_date - current_date <= 7 then 'red'
       when c.stage = 'Under Contract' and coalesce(c.funded, false) = false and c.purchase_close_date - current_date <= 14 then 'amber' end as closing_flag,
  c.reno_scope, c.reno_spent, c.reno_remaining, c.reno_pct, c.reno_start_date, c.reno_end_date,
  greatest(c.reno_spent - coalesce(c.reno_scope,0), 0) as reno_over,
  c.target_sale_price, c.list_date, c.sale_contract_date, c.sale_close_date, c.sale_price, c.sale_price_used,
  c.loan_payoff, c.est_sell_closing_costs, c.other_costs, c.est_net_proceeds,
  c.total_cash_in, c.all_in_cost, c.total_budget,
  -- gross profit is AFTER commissions/fees (sale-% and flat splits); "splits" = profit shares only
  c.profit_before_shares as gross_profit, c.net_profit as profit, c.splits_known, c.splits_detail,
  c.split_profit as splits_total, c.split_fixed + c.split_sale as sale_deductions, c.profit as profit_before_fees,
  (c.stage = 'Sold') as profit_is_actual,
  c.created_at as under_contract_date, c.notes, c.updated_at,
  prev.projected_profit as prev_profit, prev.taken_at as prev_profit_at,
  case when prev.projected_profit is not null then c.net_profit - prev.projected_profit end as profit_change,
  lu.received_at as last_update_at, lu.note as last_update_note,
  case when c.stage in ('Closed','Make-Ready') and c.purchase_close_date is not null then current_date - c.purchase_close_date
       when c.stage = 'Listed As-Is' and c.list_date is not null then current_date - c.list_date
       when c.stage = 'Renovating' and c.reno_start_date is not null then current_date - c.reno_start_date
       when c.stage = 'Listed' and c.list_date is not null then current_date - c.list_date end as phase_day,
  case when c.stage in ('Closed','Make-Ready') then 10 when c.stage = 'Listed As-Is' then 30
       when c.stage = 'Renovating' then coalesce(c.reno_end_date - c.reno_start_date, 60) end as phase_target_days,
  case when c.stage in ('Closed','Make-Ready') then c.purchase_close_date + 10
       when c.stage = 'Listed As-Is' then c.list_date + 30
       when c.stage = 'Renovating' then coalesce(c.reno_end_date, c.reno_start_date + 60) end as phase_due
from flips.house_calc c
left join lateral (
  select s.projected_profit, s.taken_at from flips.snapshots s
  where s.house_id = c.id and s.projected_profit is distinct from c.net_profit
  order by s.taken_at desc limit 1) prev on true
left join lateral (
  select u.received_at, x->>'note' as note
  from flips.updates u cross join lateral jsonb_array_elements(coalesce(u.parsed->'houses','[]'::jsonb)) x
  where u.status in ('parsed','parsed_ai') and u.source_email_id not like 'manual-%'
    and lower(trim(x->>'address')) = lower(c.address) and nullif(btrim(x->>'note'),'') is not null
  order by u.received_at desc limit 1) lu on true;





grant select on flips.dashboard to authenticated; grant all on flips.dashboard to service_role;

-- Itemized costs from Rob ("costs":[{"id","date","vendor","memo","amount","category"}] per house).
-- The list is the FULL set for that house: items missing from it are removed. When a category has items,
-- their sum replaces the matching single field (closing_buy -> est_buy_closing_costs, closing_sell ->
-- est_sell_closing_costs, holding+other -> other_costs). reno items add to reno spent next to QuickBooks.
create or replace function flips.apply_rob_costs(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare h jsonb; hid bigint; keys text[];
begin
  for h in select * from jsonb_array_elements(coalesce(p->'parsed'->'houses','[]')) loop
    if jsonb_typeof(h->'costs') <> 'array' then continue; end if;
    select id into hid from flips.houses where lower(address) = lower(btrim(h->>'address'));
    if hid is null then continue; end if;
    select coalesce(array_agg('rob:' || hid || ':' || coalesce(nullif(x->>'id',''), md5(coalesce(x->>'date','') || coalesce(x->>'vendor','') || coalesce(x->>'memo','') || coalesce(x->>'amount','')))), '{}')
      into keys from jsonb_array_elements(h->'costs') x;
    delete from flips.costs where source = 'rob' and house_id = hid and not (qb_txn_id = any(keys));
    insert into flips.costs(house_id, source, qb_txn_id, qb_doc_type, txn_date, vendor, memo, amount, category)
    select hid, 'rob', 'rob:' || hid || ':' || coalesce(nullif(x->>'id',''), md5(coalesce(x->>'date','') || coalesce(x->>'vendor','') || coalesce(x->>'memo','') || coalesce(x->>'amount',''))),
           'From Rob', flips.dt(x->>'date'), x->>'vendor', x->>'memo', coalesce(flips.num(x->>'amount'),0),
           case when x->>'category' in ('reno','closing_buy','closing_sell','holding','other') then x->>'category' else 'other' end
    from jsonb_array_elements(h->'costs') x
    on conflict (qb_txn_id) do update set txn_date = excluded.txn_date, vendor = excluded.vendor, memo = excluded.memo,
      amount = excluded.amount, category = excluded.category, updated_at = now();
    update flips.houses set
      est_buy_closing_costs  = coalesce((select sum(amount) from flips.costs where house_id = hid and source = 'rob' and category = 'closing_buy'), est_buy_closing_costs),
      est_sell_closing_costs = coalesce((select sum(amount) from flips.costs where house_id = hid and source = 'rob' and category = 'closing_sell'), est_sell_closing_costs),
      other_costs            = coalesce((select sum(amount) from flips.costs where house_id = hid and source = 'rob' and category in ('holding','other')), other_costs),
      updated_at = now()
    where id = hid;
  end loop;
end $$;
revoke execute on function flips.apply_rob_costs(jsonb) from public, anon, authenticated;

-- Direct update from an outside agent (Rob's Claude). Same rules as the email path; answers with result + feed.
create or replace function flips.agent_update(k text, body jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare ok boolean; r jsonb;
begin
  select true into ok from flips.agent_keys where key = k;
  if not coalesce(ok,false) then return jsonb_build_object('error','invalid key'); end if;
  if jsonb_typeof(body->'houses') <> 'array' then return jsonb_build_object('error','body must be {"houses":[...]}'); end if;
  r := flips.apply_update(jsonb_build_object('email_id', 'api-' || to_char(clock_timestamp(),'YYYYMMDD-HH24MISS-US'),
        'received_at', now(), 'raw_text', left(body::text, 20000), 'parsed', body, 'status', 'parsed'));
  return jsonb_build_object('result', r, 'feed', flips.agent_feed(k));
end $$;
revoke execute on function flips.agent_update(text, jsonb) from public, anon, authenticated;
