-- Projected profit in the as-is phase counts reno spent, not the full-rehab scope.
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



