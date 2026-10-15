-- Notes are per house: never fall back to another house's note from the same email.
create or replace view flips.dashboard with (security_invoker = true) as
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
  c.profit as gross_profit, c.net_profit as profit, c.splits_known, c.splits_detail,
  c.split_fixed + c.split_sale + c.split_profit as splits_total,
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




create or replace view flips.house_history with (security_invoker = true) as
select h.id as house_id, u.received_at, case when u.source_email_id like 'manual-%' then 'manual' else u.status end as status,
       coalesce(nullif(btrim(x->>'note'),''), 'fields updated') as note, x as fields
from flips.houses h
join flips.updates u on u.status in ('parsed','parsed_ai')
cross join lateral jsonb_array_elements(coalesce(u.parsed->'houses','[]'::jsonb)) x
where lower(trim(x->>'address')) = lower(h.address);


-- houses.notes: latest per-house note from Rob's emails
update flips.houses h set notes = r.note
from (select distinct on (lower(trim(x->>'address'))) lower(trim(x->>'address')) addr, x->>'note' note
      from flips.updates u cross join lateral jsonb_array_elements(u.parsed->'houses') x
      where u.source_email_id not like 'manual-%' and u.status in ('parsed','parsed_ai') and nullif(btrim(x->>'note'),'') is not null
      order by lower(trim(x->>'address')), u.received_at desc) r
where lower(h.address) = r.addr;
