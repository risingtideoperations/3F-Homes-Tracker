-- 3F flow: Under Contract -> Closed -> Make-Ready (~10 days, ~$1k cleanup) -> Listed As-Is (30 days)
--   -> if unsold: Renovating (45-60 days) -> Listed (after reno) -> Sale Pending -> Sold.
alter table flips.houses drop constraint if exists houses_stage_check;
alter table flips.houses add constraint houses_stage_check
  check (stage in ('Under Contract','Closed','Make-Ready','Listed As-Is','Renovating','Listed','Sale Pending','Sold'));

create or replace view flips.house_calc with (security_invoker = true) as
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


create or replace view flips.reno_daily with (security_invoker = true) as
select c.id as house_id, d::date as day,
       c.reno_remaining / (greatest(c.reno_end_date, current_date) - greatest(coalesce(c.reno_start_date, current_date), current_date) + 1) as amount
from flips.house_calc c
cross join lateral generate_series(
  greatest(coalesce(c.reno_start_date, current_date), current_date),
  greatest(c.reno_end_date, current_date), interval '1 day') d
where c.stage in ('Under Contract','Closed','Renovating') and c.reno_remaining > 0 and c.reno_end_date is not null;


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
  select u.received_at, coalesce(x->>'note', u.note) as note
  from flips.updates u cross join lateral jsonb_array_elements(coalesce(u.parsed->'houses','[]'::jsonb)) x
  where u.status in ('parsed','parsed_ai') and u.source_email_id not like 'manual-%'
    and lower(trim(x->>'address')) = lower(c.address)
  order by u.received_at desc limit 1) lu on true;



grant select on flips.dashboard to authenticated; grant all on flips.dashboard to service_role;

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
    ('loan_payoff',           h.stage in ('Sale Pending','Sold') and h.loan_payoff is null and coalesce(h.loan_amount,0) > 0, 'loan payoff at sale'),
    ('sale_splits',           h.sale_splits is null,                                      'who takes what from the sale')
  ) as x(field, missing, why)
  where x.missing
)
select h.id, h.address, h.stage, h.stage_no,
  coalesce((select jsonb_agg(jsonb_build_object('field', f.field, 'why', f.why)) from f where f.id = h.id), '[]'::jsonb) as missing,
  (select count(*) from f where f.id = h.id) as missing_count
from h;

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
        stg := case when h->>'stage' in ('Under Contract','Closed','Make-Ready','Listed As-Is','Renovating','Listed','Sale Pending','Sold')
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

