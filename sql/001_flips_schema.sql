-- 3F Homes Flip Tracker: everything lives in schema "flips".
-- Browser = read-only (authenticated + allowlisted email). n8n writes as postgres.

create schema if not exists flips;

-- ---------- tables ----------
create table if not exists flips.houses (
  id bigint generated always as identity primary key,
  address text not null unique,
  stage text not null default 'Under Contract'
    check (stage in ('Under Contract','Closed','Renovating','Listed','Sale Pending','Sold')),
  purchase_price numeric,
  purchase_close_date date,
  loan_amount numeric,
  lender text,
  earnest_money_paid numeric,
  est_buy_closing_costs numeric,
  cash_to_close numeric,            -- exact figure from Rob; wins over the calculation
  funded boolean not null default false,
  reno_scope numeric,
  reno_start_date date,
  reno_end_date date,
  target_sale_price numeric,
  list_date date,
  sale_contract_date date,
  sale_close_date date,
  sale_price numeric,
  loan_payoff numeric,
  est_sell_closing_costs numeric,
  other_costs numeric,
  notes text,
  funding_alert_sent_at timestamptz, -- one-time "closing in 7 days, not funded" email
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists flips.costs (
  id bigint generated always as identity primary key,
  house_id bigint references flips.houses(id) on delete cascade, -- null = unmatched
  source text not null check (source in ('quickbooks','manual')),
  qb_txn_id text unique,
  qb_doc_type text,
  qb_customer text,
  txn_date date,
  vendor text,
  memo text,
  amount numeric not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists costs_house_idx on flips.costs(house_id);

create table if not exists flips.updates (
  id bigint generated always as identity primary key,
  house_id bigint references flips.houses(id) on delete set null,
  received_at timestamptz not null default now(),
  source_email_id text unique,
  raw_text text,
  parsed jsonb,
  note text,
  status text not null default 'parsed'
    check (status in ('parsed','parsed_ai','unparsed','error'))
);

create table if not exists flips.snapshots (
  id bigint generated always as identity primary key,
  taken_at timestamptz not null default now(),
  house_id bigint not null references flips.houses(id) on delete cascade,
  projected_profit numeric
);
create index if not exists snapshots_house_idx on flips.snapshots(house_id, taken_at desc);

create table if not exists flips.allowed_viewers (email text primary key);
insert into flips.allowed_viewers values
  ('rashurst@live.com'),('ccrowe@rtmhouses.com'),('rmedo@rtmhouses.com')
on conflict do nothing;

create table if not exists flips.sync_state (key text primary key, value text, updated_at timestamptz default now());

-- ---------- access ----------
create or replace function flips.is_viewer() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from flips.allowed_viewers
                 where email = lower(coalesce(auth.jwt()->>'email','')))
$$;

do $$ declare t text; begin
  foreach t in array array['houses','costs','updates','snapshots','allowed_viewers','sync_state'] loop
    execute format('alter table flips.%I enable row level security', t);
    execute format('drop policy if exists viewer_read on flips.%I', t);
    execute format('create policy viewer_read on flips.%I for select to authenticated using (flips.is_viewer())', t);
  end loop;
end $$;

-- ---------- math ----------
-- One row per house with every derived number.
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
)
select b.*,
  -- money out of pocket so far: earnest always; closing cash once bought; reno + other
  coalesce(b.earnest_money_paid,0)
    + case when b.stage <> 'Under Contract' then b.cash_to_close_calc else 0 end
    + b.reno_spent + coalesce(b.other_costs,0) as total_cash_in,
  greatest(coalesce(b.reno_scope,0) - b.reno_spent, 0) as reno_remaining,
  case when coalesce(b.reno_scope,0) > 0 then round(b.reno_spent / b.reno_scope * 100, 1) end as reno_pct,
  -- profit: actual for Sold; projected uses the larger of scope and spent so unspent budget counts
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
from base b;

-- Remaining reno budget spread evenly per day over each active house's reno period.
create or replace view flips.reno_daily with (security_invoker = true) as
select c.id as house_id, d::date as day,
       c.reno_remaining / (greatest(c.reno_end_date, current_date) - greatest(coalesce(c.reno_start_date, current_date), current_date) + 1) as amount
from flips.house_calc c
cross join lateral generate_series(
  greatest(coalesce(c.reno_start_date, current_date), current_date),
  greatest(c.reno_end_date, current_date), interval '1 day') d
where c.stage not in ('Listed','Sale Pending','Sold') and c.reno_remaining > 0 and c.reno_end_date is not null;

-- Next 8 weeks (week 1 starts today), cash in and cash out.
create or replace view flips.cash_schedule with (security_invoker = true) as
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

-- Per-house dashboard row (what the cards read).
create or replace view flips.dashboard with (security_invoker = true) as
select c.id, c.address, c.stage, c.stage_no,
  c.purchase_price, c.purchase_close_date, c.loan_amount, c.lender, c.earnest_money_paid,
  c.est_buy_closing_costs, c.cash_to_close_calc as cash_to_close, c.cash_to_close_exact, c.funded,
  (c.purchase_close_date - current_date) as days_to_purchase_close,
  case when c.stage = 'Under Contract' and not c.funded and c.purchase_close_date - current_date <= 7 then 'red'
       when c.stage = 'Under Contract' and not c.funded and c.purchase_close_date - current_date <= 14 then 'amber' end as closing_flag,
  c.reno_scope, c.reno_spent, c.reno_remaining, c.reno_pct, c.reno_start_date, c.reno_end_date,
  greatest(c.reno_spent - coalesce(c.reno_scope,0), 0) as reno_over,
  c.target_sale_price, c.list_date, c.sale_contract_date, c.sale_close_date, c.sale_price,
  c.loan_payoff, c.est_sell_closing_costs, c.other_costs, c.est_net_proceeds,
  c.total_cash_in, c.profit, (c.stage = 'Sold') as profit_is_actual,
  c.created_at as under_contract_date, c.notes, c.updated_at,
  prev.projected_profit as prev_profit, prev.taken_at as prev_profit_at,
  case when prev.projected_profit is not null then c.profit - prev.projected_profit end as profit_change,
  lu.received_at as last_update_at, lu.note as last_update_note
from flips.house_calc c
left join lateral (
  select s.projected_profit, s.taken_at from flips.snapshots s
  where s.house_id = c.id and s.projected_profit is distinct from c.profit
  order by s.taken_at desc limit 1) prev on true
left join lateral (
  select u.received_at, coalesce(x->>'note', u.note) as note
  from flips.updates u cross join lateral jsonb_array_elements(coalesce(u.parsed->'houses','[]'::jsonb)) x
  where u.status in ('parsed','parsed_ai') and lower(trim(x->>'address')) = lower(c.address)
  order by u.received_at desc limit 1) lu on true;

-- Update history per house (expanded card).
create or replace view flips.house_history with (security_invoker = true) as
select h.id as house_id, u.received_at, u.status, coalesce(x->>'note', u.note) as note, x as fields
from flips.houses h
join flips.updates u on u.status in ('parsed','parsed_ai')
cross join lateral jsonb_array_elements(coalesce(u.parsed->'houses','[]'::jsonb)) x
where lower(trim(x->>'address')) = lower(h.address);

-- Top tiles + footer, one row.
create or replace view flips.summary with (security_invoker = true) as
select
  (select coalesce(sum(cash_to_close_calc),0) from flips.house_calc
     where stage = 'Under Contract' and purchase_close_date < current_date + 30) as cash_to_close_30,
  (select coalesce(sum(amount),0) from flips.reno_daily where day < current_date + 30) as reno_out_30,
  (select coalesce(sum(est_net_proceeds),0) from flips.house_calc
     where stage <> 'Sold' and sale_close_date >= current_date and sale_close_date < current_date + 30) as sale_in_30,
  (select count(*) from flips.houses where stage <> 'Sold') as houses_active,
  (select coalesce(sum(total_cash_in),0) from flips.house_calc where stage <> 'Sold') as total_cash_in,
  (select coalesce(sum(profit),0) from flips.house_calc where stage <> 'Sold') as projected_profit_active,
  (select coalesce(sum(profit),0) from flips.house_calc
     where stage = 'Sold' and date_part('year', sale_close_date) = date_part('year', current_date)) as realized_profit_ytd,
  (select count(*) from flips.updates
     where status in ('unparsed','error') and received_at > now() - interval '7 days') as unread_updates,
  greatest((select max(taken_at) from flips.snapshots),
           (select max(received_at) from flips.updates),
           (select max(updated_at) from flips.houses)) as data_as_of;

-- ---------- grants: read-only for signed-in viewers, nothing for anon ----------
revoke all on schema flips from public, anon;
revoke all on all tables in schema flips from public, anon, authenticated;
grant usage on schema flips to authenticated, service_role;
grant select on all tables in schema flips to authenticated;
grant all on all tables in schema flips to service_role;
grant execute on function flips.is_viewer() to authenticated;
revoke execute on function flips.is_viewer() from anon, public;
