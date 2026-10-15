-- Sale splits ("who takes what out of the sale") + real profit + pipeline groups.
-- sale_splits = [{"who":"Listing agent","basis":"sale","pct":3},
--                {"who":"Lender interest","basis":"fixed","amount":4200},
--                {"who":"Investor - J. Smith","basis":"profit","pct":50}]
--   sale   = % of the sale price, taken off the top
--   fixed  = flat dollars, taken off the top
--   profit = % of what's left after everything else (only when positive)
-- real profit (3F's share) = gross profit - fixed - sale % - profit %.

alter table flips.houses add column if not exists sale_splits jsonb;

drop view if exists flips.summary, flips.house_history, flips.dashboard, flips.cash_schedule, flips.reno_daily, flips.house_calc cascade;

create view flips.house_calc with (security_invoker = true) as
with spent as (
  select house_id, sum(amount) reno_spent from flips.costs where house_id is not null group by house_id
), base as (
  select h.*,
    coalesce(s.reno_spent,0) as reno_spent,
    coalesce(h.cash_to_close,
      coalesce(h.purchase_price,0) + coalesce(h.est_buy_closing_costs,0)
      - coalesce(h.loan_amount,0) - coalesce(h.earnest_money_paid,0)) as cash_to_close_calc,
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
      - coalesce(b.loan_payoff, b.loan_amount, 0)
      - coalesce(b.est_sell_closing_costs,0) as est_net_proceeds,
    array_position(array['Under Contract','Closed','Renovating','Listed','Sale Pending','Sold'], b.stage) as stage_no
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

create view flips.reno_daily with (security_invoker = true) as
select c.id as house_id, d::date as day,
       c.reno_remaining / (greatest(c.reno_end_date, current_date) - greatest(coalesce(c.reno_start_date, current_date), current_date) + 1) as amount
from flips.house_calc c
cross join lateral generate_series(
  greatest(coalesce(c.reno_start_date, current_date), current_date),
  greatest(c.reno_end_date, current_date), interval '1 day') d
where c.stage not in ('Listed','Sale Pending','Sold') and c.reno_remaining > 0 and c.reno_end_date is not null;

create view flips.cash_schedule with (security_invoker = true) as
with w as (
  select i as week_no, current_date + 7*(i-1) as week_start, current_date + 7*i - 1 as week_end
  from generate_series(1,8) i
)
select w.week_no, w.week_start, w.week_end,
  coalesce((select sum(cash_to_close_calc) from flips.house_calc c
            where c.stage = 'Under Contract' and c.purchase_close_date between w.week_start and w.week_end),0) as purchase_out,
  coalesce((select sum(amount) from flips.reno_daily r where r.day between w.week_start and w.week_end),0) as reno_out,
  coalesce((select sum(est_net_proceeds) from flips.house_calc c
            where c.stage <> 'Sold' and c.sale_close_date between w.week_start and w.week_end),0) as sale_in
from w order by w.week_no;

create view flips.dashboard with (security_invoker = true) as
select c.id, c.address, c.stage, c.stage_no,
  case c.stage when 'Under Contract' then 'Under contract'
               when 'Closed' then 'Owned, not started'
               when 'Renovating' then 'In renovation'
               when 'Listed' then 'For sale' when 'Sale Pending' then 'For sale'
               else 'Sold' end as stage_group,
  c.purchase_price, c.purchase_close_date, c.loan_amount, c.lender, c.earnest_money_paid,
  c.est_buy_closing_costs, c.cash_to_close_calc as cash_to_close, c.cash_to_close_exact, c.funded,
  (c.purchase_close_date - current_date) as days_to_purchase_close,
  case when c.stage = 'Under Contract' and not c.funded and c.purchase_close_date - current_date <= 7 then 'red'
       when c.stage = 'Under Contract' and not c.funded and c.purchase_close_date - current_date <= 14 then 'amber' end as closing_flag,
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
  where u.status in ('parsed','parsed_ai') and lower(trim(x->>'address')) = lower(c.address)
  order by u.received_at desc limit 1) lu on true;

create view flips.house_history with (security_invoker = true) as
select h.id as house_id, u.received_at, u.status, coalesce(x->>'note', u.note) as note, x as fields
from flips.houses h
join flips.updates u on u.status in ('parsed','parsed_ai')
cross join lateral jsonb_array_elements(coalesce(u.parsed->'houses','[]'::jsonb)) x
where lower(trim(x->>'address')) = lower(h.address);

create view flips.summary with (security_invoker = true) as
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
  (select count(distinct qb_customer) from flips.costs where house_id is null) as qb_unmatched_jobs,
  greatest((select max(taken_at) from flips.snapshots),
           (select max(received_at) from flips.updates),
           (select max(updated_at) from flips.houses),
           (select max(updated_at) from flips.sync_state)) as data_as_of;

grant select on flips.house_calc, flips.reno_daily, flips.cash_schedule, flips.dashboard, flips.house_history, flips.summary to authenticated;
grant all on flips.house_calc, flips.reno_daily, flips.cash_schedule, flips.dashboard, flips.house_history, flips.summary to service_role;

-- Snapshots now track real (after-split) profit.
create or replace function flips.take_snapshot() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  insert into flips.snapshots(house_id, projected_profit)
  select id, net_profit from flips.house_calc;
  get diagnostics n = row_count;
  insert into flips.sync_state(key, value, updated_at) values ('last_snapshot', now()::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return n;
end $$;
revoke execute on function flips.take_snapshot() from public, anon, authenticated;

-- Email updates may carry sale_splits: a non-empty array replaces the stored list; null/missing leaves it alone.
create or replace function flips.apply_splits(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare h jsonb;
begin
  for h in select * from jsonb_array_elements(coalesce(p->'parsed'->'houses','[]')) loop
    if jsonb_typeof(h->'sale_splits') = 'array' and jsonb_array_length(h->'sale_splits') > 0 then
      update flips.houses set sale_splits = h->'sale_splits', updated_at = now()
      where lower(address) = lower(btrim(h->>'address'));
    end if;
  end loop;
end $$;
revoke execute on function flips.apply_splits(jsonb) from public, anon, authenticated;
