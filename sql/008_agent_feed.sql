-- Read-only JSON feed for outside AI agents (Rob's Claude): what the tracker has and what it is missing.
-- Served by n8n GET /webhook/3f-flips-gaps?k=<agent key>. Service-only table, no browser access.
create table if not exists flips.agent_keys (
  name text primary key,
  key text not null unique default encode(extensions.gen_random_bytes(24), 'hex'),
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
alter table flips.agent_keys enable row level security;
revoke all on flips.agent_keys from public, anon, authenticated;
grant all on flips.agent_keys to service_role;
insert into flips.agent_keys(name) values ('Rob''s Claude (rob3fhome@gmail.com)') on conflict do nothing;

create or replace function flips.agent_feed(k text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare ok boolean;
begin
  update flips.agent_keys set last_used_at = now() where key = k returning true into ok;
  if not coalesce(ok, false) then return jsonb_build_object('error', 'invalid key'); end if;
  return jsonb_build_object(
    'what_this_is', '3F Homes Flip Tracker: every 3F flip from purchase contract to sale. Read-only. Fill the "missing" fields by emailing a 3F UPDATE (see how_to_update).',
    'as_of', now(),
    'how_to_update', jsonb_build_object(
      'preferred', 'POST the same {"houses":[...]} JSON to https://risingtideoperations.app.n8n.cloud/webhook/3f-flips-update?k=<this key> with Content-Type: application/json. Applied instantly; the reply has the result and this feed refreshed.',
      'email_backup', 'or email it: to risingtideoperations@gmail.com from rob3fhome@gmail.com, subject 3F UPDATE <date>; read at 7 AM and 5 PM Central',
      'costs', 'per house "costs":[{"id":"your stable id","date":"YYYY-MM-DD","vendor":"...","memo":"...","amount":123.45,"category":"closing_buy|closing_sell|holding|reno|other"}] = the FULL list of costs NOT in Renovation Depot QuickBooks; items left out are removed; each category total replaces the matching single field',
      'profit_math', 'gross_profit = sale price - purchase - buy closing - reno (QuickBooks incl. markup + your reno items) - other costs - sell closing - commissions/flat fees (sale_splits basis sale/fixed); real_profit_to_3f = gross_profit - profit shares (basis profit)',
      'body', 'One ```json fenced block: {"houses":[{"address":...,"<field>":<value>,...}]}. Only send fields you know; null never erases. Numbers plain, dates YYYY-MM-DD.',
      'stages', jsonb_build_array('Under Contract','Closed','Make-Ready','Listed As-Is','Renovating','Listed','Sale Pending','Sold'),
      'flow', 'Under Contract -> Closed -> Make-Ready (~10 days, ~$1k cleanup) -> Listed As-Is (30 days) -> if unsold: Renovating (45-60 days) -> Listed -> Sale Pending -> Sold',
      'sale_splits', 'list of {"who","basis":"sale"|"fixed"|"profit","pct" or "amount"}; sale/fixed come off the top, profit % applies to what is left'),
    'houses', (select coalesce(jsonb_agg(jsonb_build_object(
        'address', d.address, 'stage', d.stage,
        'missing', g.missing,
        'have', jsonb_strip_nulls(jsonb_build_object(
          'purchase_price', h.purchase_price, 'purchase_close_date', h.purchase_close_date, 'funded', h.funded,
          'loan_amount', h.loan_amount, 'earnest_money_paid', h.earnest_money_paid, 'est_buy_closing_costs', h.est_buy_closing_costs,
          'reno_scope', h.reno_scope, 'reno_spent_quickbooks_incl_markup', d.reno_spent, 'reno_start_date', h.reno_start_date, 'reno_end_date', h.reno_end_date,
          'target_sale_price', h.target_sale_price, 'list_date', h.list_date, 'sale_contract_date', h.sale_contract_date,
          'sale_close_date', h.sale_close_date, 'sale_price', h.sale_price, 'est_sell_closing_costs', h.est_sell_closing_costs,
          'other_costs', h.other_costs, 'sale_splits', h.sale_splits, 'lender', h.lender, 'notes', h.notes,
          'your_itemized_costs', (select jsonb_agg(jsonb_build_object('id', split_part(c.qb_txn_id, ':', 3), 'date', c.txn_date, 'vendor', c.vendor, 'memo', c.memo, 'amount', c.amount, 'category', c.category)) from flips.costs c where c.house_id = h.id and c.source = 'rob'),
          'commissions_and_fees', d.sale_deductions, 'partner_shares', d.splits_total,
          'gross_profit', d.gross_profit, 'real_profit_to_3f', d.profit))
      ) order by d.stage_no, d.address), '[]'::jsonb)
      from flips.dashboard d join flips.houses h on h.id = d.id join flips.gaps g on g.id = d.id),
    'quickbooks_jobs_not_in_tracker', (select coalesce(jsonb_agg(jsonb_build_object('job', qb_customer, 'renovation_depot_invoiced_incl_markup', total) order by qb_customer), '[]'::jsonb)
      from (select qb_customer, sum(amount) total from flips.costs c where house_id is null and not exists (select 1 from flips.qb_job_ignore i where i.qb_customer = c.qb_customer) group by 1) x),
    'quickbooks_jobs_note', 'Renovation Depot jobs under "3F Homes LLC" with no matching house here. Say which are sold (add them as stage Sold with sale data) and which are not 3F flips.'
  );
end $$;
revoke execute on function flips.agent_feed(text) from public, anon, authenticated;
