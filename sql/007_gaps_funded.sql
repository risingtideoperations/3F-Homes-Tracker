-- Funded can now be unknown (null) instead of silently false; unknown still triggers the 7-day alert.
-- "Last update from Rob" ignores manual fills. flips.gaps lists what each house is still missing.
alter table flips.houses alter column funded drop not null, alter column funded set default null;
update flips.houses set funded = null
where stage = 'Under Contract' and funded = false and id in (
  select h.id from flips.houses h join flips.updates u on u.status in ('parsed','parsed_ai')
  cross join lateral jsonb_array_elements(u.parsed->'houses') x
  where lower(trim(x->>'address')) = lower(h.address) group by h.id
  having bool_and(x->'funded' is null or x->>'funded' is null));

create or replace view flips.dashboard with (security_invoker = true) as
select c.id, c.address, c.stage, c.stage_no,
  case c.stage when 'Under Contract' then 'Under contract'
               when 'Closed' then 'Owned, not started'
               when 'Renovating' then 'In renovation'
               when 'Listed' then 'For sale' when 'Sale Pending' then 'For sale'
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
  c.profit as gross_profit, c.net_profit as profit, c.splits_known, c.splits_detail,
  c.split_fixed + c.split_sale + c.split_profit as splits_total,
  (c.stage = 'Sold') as profit_is_actual,
  c.created_at as under_contract_date, c.notes, c.updated_at,
  prev.projected_profit as prev_profit, prev.taken_at as prev_profit_at,
  case when prev.projected_profit is not null then c.net_profit - prev.projected_profit end as profit_change,
  lu.received_at as last_update_at, lu.note as last_update_note
from flips.house_calc c
left join lateral (
  select s.projected_profit, s.taken_at from flips.snapshots s
  where s.house_id = c.id and s.projected_profit is distinct from c.net_profit
  order by s.taken_at desc limit 1) prev on true
left join lateral (
  select u.received_at, coalesce(x->>'note', u.note) as note
  from flips.updates u cross join lateral jsonb_array_elements(coalesce(u.parsed->'houses','[]'::jsonb)) x
  where u.status in ('parsed','parsed_ai') and u.source_email_id not like 'manual-%'
    and lower(trim(x->>'address')) = lower(c.address)
  order by u.received_at desc limit 1) lu on true;


create or replace function flips.funding_alerts_due() returns table(id bigint, address text, purchase_close_date date, cash_to_close numeric, days_out int)
language sql security definer set search_path = '' as $$
  select d.id, d.address, d.purchase_close_date, d.cash_to_close, d.days_to_purchase_close
  from flips.dashboard d join flips.houses h on h.id = d.id
  where d.stage = 'Under Contract' and coalesce(d.funded, false) = false and h.funding_alert_sent_at is null
    and d.days_to_purchase_close between 0 and 7
$$;
revoke execute on function flips.funding_alerts_due() from public, anon, authenticated;

create or replace view flips.gaps with (security_invoker = true) as
with h as (select * from flips.house_calc),
f as (
  select h.id, h.address, h.stage, x.field, x.why
  from h cross join lateral (values
    ('purchase_price',        h.purchase_price is null,                                   'needed for every number'),
    ('purchase_close_date',   h.purchase_close_date is null,                              'drives the closing countdown and cash schedule'),
    ('funded',                h.stage = 'Under Contract' and h.funded is null,            'true/false: is the cash to close in place?'),
    ('loan_amount',           h.stage in ('Under Contract','Closed','Renovating') and h.loan_amount is null, 'loan amount, or 0 if it is a cash buy'),
    ('est_buy_closing_costs', h.est_buy_closing_costs is null,                            'buy-side closing costs (0 if none)'),
    ('reno_scope',            h.stage <> 'Sold' and h.reno_scope is null,                 'reno budget; without it there is no over/under-budget check'),
    ('reno_start_date',       h.stage in ('Renovating') and h.reno_start_date is null,    'spreads the remaining reno budget over the cash schedule'),
    ('reno_end_date',         h.stage in ('Closed','Renovating') and h.reno_end_date is null, 'planned reno completion date'),
    ('target_sale_price',     h.stage <> 'Sold' and h.target_sale_price is null,          'expected sale or list price; without it profit is blank'),
    ('list_date',             h.stage in ('Listed','Sale Pending') and h.list_date is null, 'date it went on the market'),
    ('sale_contract_date',    h.stage = 'Sale Pending' and h.sale_contract_date is null,  'date the sale went under contract'),
    ('sale_close_date',       h.stage in ('Sale Pending','Sold') and h.sale_close_date is null, 'sale closing date'),
    ('sale_price',            h.stage = 'Sold' and h.sale_price is null,                  'final sale price'),
    ('est_sell_closing_costs',h.stage in ('Sale Pending','Sold') and h.est_sell_closing_costs is null, 'seller title/closing fees (not commissions)'),
    ('loan_payoff',           h.stage in ('Sale Pending','Sold') and h.loan_payoff is null and coalesce(h.loan_amount,0) > 0, 'loan payoff at sale'),
    ('sale_splits',           h.sale_splits is null,                                      'who takes what from the sale')
  ) as x(field, missing, why)
  where x.missing
)
select h.id, h.address, h.stage, h.stage_no,
  coalesce((select jsonb_agg(jsonb_build_object('field', f.field, 'why', f.why)) from f where f.id = h.id), '[]'::jsonb) as missing,
  (select count(*) from f where f.id = h.id) as missing_count
from h;
grant select on flips.gaps to authenticated;
grant all on flips.gaps to service_role;
