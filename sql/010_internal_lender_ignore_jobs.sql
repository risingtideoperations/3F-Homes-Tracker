-- Rising Tide is 3F's in-house lender: its loan does not reduce the cash that has to go out at closing,
-- and its payoff stays in the family, so only outside lenders reduce cash to close / net proceeds.
-- Old 3F QuickBooks jobs Rob said to disregard are parked in flips.qb_job_ignore.

create or replace view flips.house_calc with (security_invoker = true) as
with spent as (
  select house_id, sum(amount) reno_spent from flips.costs where house_id is not null group by house_id
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
      - case when b.stage = 'Sold' then b.reno_spent else greatest(b.reno_spent, coalesce(b.reno_scope,0)) end
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



create or replace view flips.gaps with (security_invoker = true) as
with h as (select * from flips.house_calc),
f as (
  select h.id, h.address, h.stage, x.field, x.why
  from h cross join lateral (values
    ('purchase_price',        h.purchase_price is null,                                   'needed for every number'),
    ('purchase_close_date',   h.purchase_close_date is null,                              'drives the closing countdown and cash schedule'),
    ('funded',                h.stage = 'Under Contract' and h.funded is null,            'true/false: is the cash to close in place?'),
    ('loan_amount',           h.stage not in ('Sold') and h.loan_amount is null, 'loan amount, or 0 if it is a cash buy'),
    ('est_buy_closing_costs', h.est_buy_closing_costs is null,                            'buy-side closing costs (0 if none)'),
    ('reno_scope',            h.stage <> 'Sold' and h.reno_scope is null,                 'reno budget; without it there is no over/under-budget check'),
    ('reno_start_date',       h.stage in ('Renovating') and h.reno_start_date is null,    'spreads the remaining reno budget over the cash schedule'),
    ('reno_end_date',         h.stage = 'Renovating' and h.reno_end_date is null, 'planned reno completion date'),
    ('target_sale_price',     h.stage <> 'Sold' and h.target_sale_price is null,          'expected sale or list price; without it profit is blank'),
    ('list_date',             h.stage in ('Listed As-Is','Listed','Sale Pending') and h.list_date is null, 'date it went on the market'),
    ('sale_contract_date',    h.stage = 'Sale Pending' and h.sale_contract_date is null,  'date the sale went under contract'),
    ('sale_close_date',       h.stage in ('Sale Pending','Sold') and h.sale_close_date is null, 'sale closing date'),
    ('sale_price',            h.stage = 'Sold' and h.sale_price is null,                  'final sale price'),
    ('est_sell_closing_costs',h.stage in ('Sale Pending','Sold') and h.est_sell_closing_costs is null, 'seller title/closing fees (not commissions)'),
    ('loan_payoff',           h.stage in ('Sale Pending','Sold') and h.loan_payoff is null and coalesce(h.loan_amount,0) > 0 and coalesce(h.lender,'') not ilike 'rising tide%', 'loan payoff at sale'),
    ('sale_splits',           h.sale_splits is null,                                      'who takes what from the sale')
  ) as x(field, missing, why)
  where x.missing
)
select h.id, h.address, h.stage, h.stage_no,
  coalesce((select jsonb_agg(jsonb_build_object('field', f.field, 'why', f.why)) from f where f.id = h.id), '[]'::jsonb) as missing,
  (select count(*) from f where f.id = h.id) as missing_count
from h;


create table if not exists flips.qb_job_ignore (qb_customer text primary key, reason text, created_at timestamptz default now());
alter table flips.qb_job_ignore enable row level security;
drop policy if exists viewer_read on flips.qb_job_ignore;
create policy viewer_read on flips.qb_job_ignore for select to authenticated using (flips.is_viewer());
grant select on flips.qb_job_ignore to authenticated; grant all on flips.qb_job_ignore to service_role;
insert into flips.qb_job_ignore(qb_customer, reason)
select unnest(array['1005 Regency','1020 Rutledge Dr','117 Kensington Ln','146 Sugar Dr','1509 Hidden Lake Dr','1680 Russett Dr','1852 Windsor Blvd','3302 15th Ct','3314 Chase Court','4220 Highway 11','4229 Montevallo','460 Beasley Rd','5600 Double Tree Dr','588 Forest Lake Dr','6250 S Clubview Circle','7329 Old Bradford Rd']),
       'Rob 10/15: old 3F flips, disregard'
on conflict do nothing;

create or replace view flips.summary with (security_invoker = true) as
select
  (select coalesce(sum(cash_to_close_calc),0) from flips.house_calc
     where stage = 'Under Contract' and purchase_close_date < current_date + 30) as cash_to_close_30,
  (select coalesce(sum(amount),0) from flips.reno_daily where day < current_date + 30) as reno_out_30,
  (select coalesce(sum(est_net_proceeds),0) from flips.house_calc
     where stage <> 'Sold' and sale_close_date >= current_date and sale_close_date < current_date + 30) as sale_in_30,
  (select count(*) from flips.houses where stage <> 'Sold') as houses_active,
  (select coalesce(sum(total_cash_in),0) from flips.house_calc where stage <> 'Sold') as total_cash_in,
  (select coalesce(sum(net_profit),0) from flips.house_calc where stage <> 'Sold') as projected_profit_active,
  (select coalesce(sum(profit),0) from flips.house_calc where stage <> 'Sold') as projected_gross_active,
  (select coalesce(sum(net_profit),0) from flips.house_calc
     where stage = 'Sold' and date_part('year', sale_close_date) = date_part('year', current_date)) as realized_profit_ytd,
  (select count(*) from flips.house_calc where not splits_known) as houses_missing_splits,
  (select count(*) from flips.updates
     where status in ('unparsed','error') and received_at > now() - interval '7 days') as unread_updates,
  (select count(distinct qb_customer) from flips.costs c where house_id is null and not exists (select 1 from flips.qb_job_ignore i where i.qb_customer = c.qb_customer)) as qb_unmatched_jobs,
  greatest((select max(taken_at) from flips.snapshots),
           (select max(received_at) from flips.updates),
           (select max(updated_at) from flips.houses),
           (select max(updated_at) from flips.sync_state)) as data_as_of;

