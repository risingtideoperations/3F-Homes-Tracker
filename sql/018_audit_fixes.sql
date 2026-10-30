-- Fixes from the 10/30 audit.
-- 1. As-is stages: profit used the after-reno target with $0 reno. Now only when an as-is price is known.
-- 2. Funding alert skipped funded = unknown; resets when the closing date moves.
-- 3. One address resolver (punctuation-insensitive) for updates, splits, costs, history and last note.
-- 4. A bad cost list no longer fails the email silently; duplicates are collapsed.
-- 5. Cost category totals follow Rob's full list (dropped items go to 0). A house sent without a costs
--    list no longer has its itemized costs deleted (915 Lane lost its rows this way; its totals survived).
-- 6. "clear":[...] empties fields; moving back to a listing clears the sale dates.
-- 7. Make-Ready stops counting overdue once a list date is set; gaps flag stale stages and past sale dates.
-- 9. Removed houses put their QuickBooks jobs on the ignore list.
-- Every applied email stores warnings (new house, fuzzy match, no match, unknown stage, ignored keys).

alter table flips.houses add column if not exists as_is_price numeric;
alter table flips.updates add column if not exists warnings jsonb;

create or replace function flips.addr_key(a text) returns text
language sql immutable as $$
  select nullif(substring(regexp_replace(regexp_replace(lower(coalesce(a,'')), '[^a-z0-9 ]', '', 'g'), '\s+', ' ', 'g')
                          from '^\s*(\d+[a-z]?\s+[a-z0-9]+)'), '')
$$;

-- Exact address first, then house number + first street word when exactly one house has it.
create or replace function flips.find_house(a text) returns bigint
language sql stable set search_path = '' as $$
  select coalesce(
    (select id from flips.houses where lower(address) = lower(btrim(a))),
    (select min(id) from flips.houses where flips.addr_key(address) = flips.addr_key(a) having count(*) = 1))
$$;

create or replace function flips.apply_splits(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare h jsonb;
begin
  for h in select * from jsonb_array_elements(coalesce(p->'parsed'->'houses','[]')) loop
    if jsonb_typeof(h->'sale_splits') = 'array' and jsonb_array_length(h->'sale_splits') > 0 then
      update flips.houses set sale_splits = h->'sale_splits', updated_at = now()
      where id = flips.find_house(h->>'address');
    end if;
  end loop;
end $$;

-- Rob's "costs" list is the FULL set for that house: items missing from it are removed, and a category
-- with no items left goes to 0 if Rob had sent items for it before.
create or replace function flips.apply_rob_costs(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare h jsonb; hid bigint; had text[];
begin
  for h in select * from jsonb_array_elements(coalesce(p->'parsed'->'houses','[]')) loop
    -- No costs list for this house means "no change", not "delete them all" (the old check let null through).
    if coalesce(jsonb_typeof(h->'costs'), '') <> 'array' then continue; end if;
    hid := flips.find_house(h->>'address');
    if hid is null then continue; end if;
    select coalesce(array_agg(distinct category), '{}') into had from flips.costs where house_id = hid and source = 'rob';
    create temp table if not exists pg_temp._rc(k text primary key, d date, v text, m text, a numeric, c text) on commit drop;
    truncate pg_temp._rc;
    insert into pg_temp._rc
    select distinct on (k) k, d, v, m, a, c from (
      select 'rob:' || hid || ':' || coalesce(nullif(x->>'id',''), md5(coalesce(x->>'date','') || coalesce(x->>'vendor','') || coalesce(x->>'memo','') || coalesce(x->>'amount',''))) k,
             flips.dt(x->>'date') d, x->>'vendor' v, x->>'memo' m, coalesce(flips.num(x->>'amount'),0) a,
             case when x->>'category' in ('reno','closing_buy','closing_sell','holding','other') then x->>'category' else 'other' end c
      from jsonb_array_elements(h->'costs') x) q
    order by k;
    delete from flips.costs where source = 'rob' and house_id = hid and qb_txn_id not in (select k from pg_temp._rc);
    insert into flips.costs(house_id, source, qb_txn_id, qb_doc_type, txn_date, vendor, memo, amount, category)
    select hid, 'rob', k, 'From Rob', d, v, m, a, c from pg_temp._rc
    on conflict (qb_txn_id) do update set txn_date = excluded.txn_date, vendor = excluded.vendor, memo = excluded.memo,
      amount = excluded.amount, category = excluded.category, updated_at = now();
    update flips.houses set
      est_buy_closing_costs  = coalesce((select sum(amount) from flips.costs where house_id = hid and source = 'rob' and category = 'closing_buy'),
                                        case when 'closing_buy' = any(had) then 0 end, est_buy_closing_costs),
      est_sell_closing_costs = coalesce((select sum(amount) from flips.costs where house_id = hid and source = 'rob' and category = 'closing_sell'),
                                        case when 'closing_sell' = any(had) then 0 end, est_sell_closing_costs),
      other_costs            = coalesce((select sum(amount) from flips.costs where house_id = hid and source = 'rob' and category in ('holding','other')),
                                        case when had && array['holding','other'] then 0 end, other_costs),
      updated_at = now()
    where id = hid;
  end loop;
end $$;

-- Only QuickBooks jobs not on the ignore list get attached to houses.
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
    and keys.k = flips.addr_key(c.qb_customer)
    and not exists (select 1 from flips.qb_job_ignore i where i.qb_customer = c.qb_customer);
  get diagnostics k = row_count;
  return k;
end $$;

create or replace function flips.apply_update(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  st text := coalesce(p->>'status', 'parsed');
  h jsonb; hid bigint; n int := 0; ids bigint[] := '{}'; first_note text;
  stg text; cur_stage text; clr text[]; warn jsonb := '[]'; k text;
  stages text[] := array['Under Contract','Closed','Make-Ready','Listed As-Is','Renovating','Listed','Sale Pending','Sold'];
  known text[] := array['address','stage','note','costs','sale_splits','remove','clear','purchase_price','purchase_close_date',
    'loan_amount','lender','earnest_money_paid','est_buy_closing_costs','cash_to_close','funded','reno_scope','reno_start_date',
    'reno_end_date','target_sale_price','as_is_price','list_date','sale_contract_date','sale_close_date','sale_price','loan_payoff',
    'est_sell_closing_costs','other_costs'];
  clearable text[] := array['sale_contract_date','sale_close_date','sale_price','list_date','reno_start_date','reno_end_date',
    'target_sale_price','as_is_price','loan_payoff','cash_to_close','funded','purchase_close_date'];
begin
  if exists (select 1 from flips.updates where source_email_id = p->>'email_id') then
    return jsonb_build_object('ok', true, 'skipped', 'already processed');
  end if;

  if st in ('parsed','parsed_ai') and jsonb_typeof(p->'parsed'->'houses') = 'array' then
    begin
      for h in select * from jsonb_array_elements(p->'parsed'->'houses') loop
        if nullif(btrim(h->>'address'), '') is null then continue; end if;
        for k in select jsonb_object_keys(h) loop
          if not (k = any(known)) then warn := warn || jsonb_build_object('address', h->>'address', 'warning', 'ignored field: ' || k); end if;
        end loop;
        -- Case-insensitive stage names ("Make Ready", "listed as-is"); anything else is reported, not guessed.
        stg := (select s from unnest(stages) s where lower(regexp_replace(s, '[^A-Za-z]', '', 'g')) = lower(regexp_replace(coalesce(h->>'stage',''), '[^A-Za-z]', '', 'g')));
        if nullif(h->>'stage','') is not null and stg is null and h->>'stage' not ilike 'cancel%' then
          warn := warn || jsonb_build_object('address', h->>'address', 'warning', 'unknown stage: ' || (h->>'stage'));
        end if;
        hid := flips.find_house(h->>'address');
        if hid is not null and not exists (select 1 from flips.houses where id = hid and lower(address) = lower(btrim(h->>'address'))) then
          warn := warn || jsonb_build_object('address', h->>'address', 'warning',
                    'matched to ' || (select address from flips.houses where id = hid));
        end if;
        -- Cancelled contracts come off the tracker ("stage":"Cancelled", "remove":true, or a "remove from tracker" note).
        if h->>'stage' ilike 'cancel%' or h->>'remove' = 'true' or h->>'note' ilike '%remove from tracker%' then
          if hid is not null then
            insert into flips.qb_job_ignore(qb_customer, reason)
            select distinct qb_customer, 'house removed: ' || (h->>'address') from flips.costs
            where house_id = hid and source = 'quickbooks' and qb_customer is not null
            on conflict do nothing;
            delete from flips.snapshots where house_id = hid;
            delete from flips.costs where house_id = hid and source = 'rob';
            update flips.costs set house_id = null where house_id = hid;
            update flips.updates set house_id = null where house_id = hid;
            delete from flips.houses where id = hid;
            warn := warn || jsonb_build_object('address', h->>'address', 'warning', 'removed from tracker');
            n := n + 1;
          end if;
          continue;
        end if;
        if hid is null then
          if stg is not null and stg <> 'Under Contract' then
            warn := warn || jsonb_build_object('address', h->>'address', 'warning', 'address not matched; not added (stage ' || stg || ')');
            continue;
          end if;
          insert into flips.houses(address, stage) values (btrim(h->>'address'), coalesce(stg, 'Under Contract'))
          returning id into hid;
          warn := warn || jsonb_build_object('address', h->>'address', 'warning', 'new house added');
        end if;
        select stage into cur_stage from flips.houses where id = hid;
        clr := array(select jsonb_array_elements_text(case when jsonb_typeof(h->'clear') = 'array' then h->'clear' else '[]' end)
                     intersect select unnest(clearable));
        -- Back to a listing from Sale Pending: the old sale dates are no longer true.
        if stg in ('Listed','Listed As-Is') and cur_stage = 'Sale Pending' then
          clr := clr || array['sale_contract_date','sale_close_date'];
        end if;
        update flips.houses set
          stage                  = coalesce(stg, stage),
          purchase_price         = coalesce(flips.num(h->>'purchase_price'), purchase_price),
          purchase_close_date    = case when 'purchase_close_date' = any(clr) then null else coalesce(flips.dt(h->>'purchase_close_date'), purchase_close_date) end,
          funding_alert_sent_at  = case when flips.dt(h->>'purchase_close_date') is distinct from purchase_close_date
                                         and flips.dt(h->>'purchase_close_date') is not null then null else funding_alert_sent_at end,
          loan_amount            = coalesce(flips.num(h->>'loan_amount'), loan_amount),
          lender                 = coalesce(nullif(btrim(h->>'lender'), ''), lender),
          earnest_money_paid     = coalesce(flips.num(h->>'earnest_money_paid'), earnest_money_paid),
          est_buy_closing_costs  = coalesce(flips.num(h->>'est_buy_closing_costs'), est_buy_closing_costs),
          cash_to_close          = case when 'cash_to_close' = any(clr) then null else coalesce(flips.num(h->>'cash_to_close'), cash_to_close) end,
          funded                 = case when 'funded' = any(clr) then null else coalesce((case when h->>'funded' in ('true','false') then (h->>'funded')::boolean end), funded) end,
          reno_scope             = coalesce(flips.num(h->>'reno_scope'), reno_scope),
          reno_start_date        = case when 'reno_start_date' = any(clr) then null else coalesce(flips.dt(h->>'reno_start_date'), reno_start_date) end,
          reno_end_date          = case when 'reno_end_date' = any(clr) then null else coalesce(flips.dt(h->>'reno_end_date'), reno_end_date) end,
          target_sale_price      = case when 'target_sale_price' = any(clr) then null else coalesce(flips.num(h->>'target_sale_price'), target_sale_price) end,
          as_is_price            = case when 'as_is_price' = any(clr) then null else coalesce(flips.num(h->>'as_is_price'), as_is_price) end,
          list_date              = case when 'list_date' = any(clr) then null else coalesce(flips.dt(h->>'list_date'), list_date) end,
          sale_contract_date     = case when 'sale_contract_date' = any(clr) and flips.dt(h->>'sale_contract_date') is null then null else coalesce(flips.dt(h->>'sale_contract_date'), sale_contract_date) end,
          sale_close_date        = case when 'sale_close_date' = any(clr) and flips.dt(h->>'sale_close_date') is null then null else coalesce(flips.dt(h->>'sale_close_date'), sale_close_date) end,
          sale_price             = case when 'sale_price' = any(clr) then null else coalesce(flips.num(h->>'sale_price'), sale_price) end,
          loan_payoff            = case when 'loan_payoff' = any(clr) then null else coalesce(flips.num(h->>'loan_payoff'), loan_payoff) end,
          est_sell_closing_costs = coalesce(flips.num(h->>'est_sell_closing_costs'), est_sell_closing_costs),
          other_costs            = coalesce(flips.num(h->>'other_costs'), other_costs),
          notes                  = coalesce(nullif(btrim(h->>'note'), ''), notes),
          updated_at             = now()
        where id = hid;
        n := n + 1; ids := ids || hid;
        first_note := coalesce(first_note, nullif(btrim(h->>'note'), ''));
      end loop;
      perform flips.apply_splits(p);
      perform flips.apply_rob_costs(p);
    exception when others then
      insert into flips.updates(source_email_id, received_at, raw_text, parsed, note, status, warnings)
      values (p->>'email_id', coalesce((p->>'received_at')::timestamptz, now()), p->>'raw_text', p->'parsed',
              'Error: ' || sqlerrm, 'error', warn);
      return jsonb_build_object('ok', false, 'status', 'error', 'error', sqlerrm);
    end;
    if n = 0 then st := 'unparsed'; end if;
  elsif st not in ('error') then
    st := 'unparsed';
  end if;

  insert into flips.updates(house_id, source_email_id, received_at, raw_text, parsed, note, status, warnings)
  values (case when array_length(ids,1) = 1 then ids[1] end, p->>'email_id',
          coalesce((p->>'received_at')::timestamptz, now()), p->>'raw_text', p->'parsed',
          coalesce(first_note, p->>'error'), st, nullif(warn, '[]'::jsonb));
  perform flips.rematch_costs();
  return jsonb_build_object('ok', st in ('parsed','parsed_ai'), 'status', st, 'houses', n, 'warnings', warn);
end $$;

create or replace function flips.funding_alerts_due() returns table(id bigint, address text, purchase_close_date date, cash_to_close numeric, days_out int)
language sql security definer set search_path = '' as $$
  select d.id, d.address, d.purchase_close_date, d.cash_to_close, d.days_to_purchase_close
  from flips.dashboard d join flips.houses h on h.id = d.id
  where d.stage = 'Under Contract' and coalesce(d.funded, false) = false and h.funding_alert_sent_at is null
    and d.days_to_purchase_close between 0 and 7
$$;

revoke execute on function flips.apply_update(jsonb), flips.apply_splits(jsonb), flips.apply_rob_costs(jsonb),
  flips.rematch_costs(), flips.funding_alerts_due() from public, anon, authenticated;

create or replace view flips.house_calc with (security_invoker = true) as
 WITH spent AS (
         SELECT costs.house_id,
            sum(costs.amount) AS reno_spent
           FROM flips.costs
          WHERE costs.house_id IS NOT NULL AND (costs.source = 'quickbooks'::text OR costs.category = 'reno'::text)
          GROUP BY costs.house_id
        ), base AS (
         SELECT h.id,
            h.address,
            h.stage,
            h.purchase_price,
            h.purchase_close_date,
            h.loan_amount,
            h.lender,
            h.earnest_money_paid,
            h.est_buy_closing_costs,
            h.cash_to_close,
            h.funded,
            h.reno_scope,
            h.reno_start_date,
            h.reno_end_date,
            h.target_sale_price,
            h.list_date,
            h.sale_contract_date,
            h.sale_close_date,
            h.sale_price,
            h.loan_payoff,
            h.est_sell_closing_costs,
            h.other_costs,
            h.notes,
            h.funding_alert_sent_at,
            h.created_at,
            h.updated_at,
            h.sale_splits,
            COALESCE(s_1.reno_spent, 0::numeric) AS reno_spent,
            h.as_is_price,
            COALESCE(h.cash_to_close, COALESCE(h.purchase_price, 0::numeric) + COALESCE(h.est_buy_closing_costs, 0::numeric) -
                CASE
                    WHEN h.lender ~~* 'rising tide%'::text THEN 0::numeric
                    ELSE COALESCE(h.loan_amount, 0::numeric)
                END - COALESCE(h.earnest_money_paid, 0::numeric)) AS cash_to_close_calc,
            h.cash_to_close IS NOT NULL AS cash_to_close_exact,
            COALESCE(h.sale_price, CASE WHEN h.stage = ANY (ARRAY['Closed'::text, 'Make-Ready'::text, 'Listed As-Is'::text]) THEN h.as_is_price END, h.target_sale_price) AS sale_price_used
           FROM flips.houses h
             LEFT JOIN spent s_1 ON s_1.house_id = h.id
        ), g AS (
         SELECT b.id,
            b.address,
            b.stage,
            b.purchase_price,
            b.purchase_close_date,
            b.loan_amount,
            b.lender,
            b.earnest_money_paid,
            b.est_buy_closing_costs,
            b.cash_to_close,
            b.funded,
            b.reno_scope,
            b.reno_start_date,
            b.reno_end_date,
            b.target_sale_price,
            b.list_date,
            b.sale_contract_date,
            b.sale_close_date,
            b.sale_price,
            b.loan_payoff,
            b.est_sell_closing_costs,
            b.other_costs,
            b.notes,
            b.funding_alert_sent_at,
            b.created_at,
            b.updated_at,
            b.sale_splits,
            b.reno_spent,
            b.as_is_price,
            b.cash_to_close_calc,
            b.cash_to_close_exact,
            b.sale_price_used,
            COALESCE(b.earnest_money_paid, 0::numeric) +
                CASE
                    WHEN b.stage <> 'Under Contract'::text THEN b.cash_to_close_calc
                    ELSE 0::numeric
                END + b.reno_spent + COALESCE(b.other_costs, 0::numeric) AS total_cash_in,
            GREATEST(COALESCE(b.reno_scope, 0::numeric) - b.reno_spent, 0::numeric) AS reno_remaining,
                CASE
                    WHEN COALESCE(b.reno_scope, 0::numeric) > 0::numeric THEN round(b.reno_spent / b.reno_scope * 100::numeric, 1)
                    ELSE NULL::numeric
                END AS reno_pct,
            COALESCE(b.purchase_price, 0::numeric) + COALESCE(b.est_buy_closing_costs, 0::numeric) + b.reno_spent + COALESCE(b.other_costs, 0::numeric) AS all_in_cost,
            COALESCE(b.purchase_price, 0::numeric) + COALESCE(b.est_buy_closing_costs, 0::numeric) + COALESCE(b.reno_scope, 0::numeric) + COALESCE(b.other_costs, 0::numeric) AS total_budget,
            b.sale_price_used - COALESCE(b.purchase_price, 0::numeric) -
                CASE
                    WHEN b.stage = 'Sold'::text OR (b.stage = ANY (ARRAY['Closed'::text, 'Make-Ready'::text, 'Listed As-Is'::text])) AND b.as_is_price IS NOT NULL THEN b.reno_spent
                    ELSE GREATEST(b.reno_spent, COALESCE(b.reno_scope, 0::numeric))
                END - COALESCE(b.other_costs, 0::numeric) - COALESCE(b.est_buy_closing_costs, 0::numeric) - COALESCE(b.est_sell_closing_costs, 0::numeric) AS profit,
            b.sale_price_used -
                CASE
                    WHEN b.lender ~~* 'rising tide%'::text THEN 0::numeric
                    ELSE COALESCE(b.loan_payoff, b.loan_amount, 0::numeric)
                END - COALESCE(b.est_sell_closing_costs, 0::numeric) AS est_net_proceeds,
            array_position(ARRAY['Under Contract'::text, 'Closed'::text, 'Make-Ready'::text, 'Listed As-Is'::text, 'Renovating'::text, 'Listed'::text, 'Sale Pending'::text, 'Sold'::text], b.stage) AS stage_no
           FROM base b
        ), s AS (
         SELECT g.id,
            g.address,
            g.stage,
            g.purchase_price,
            g.purchase_close_date,
            g.loan_amount,
            g.lender,
            g.earnest_money_paid,
            g.est_buy_closing_costs,
            g.cash_to_close,
            g.funded,
            g.reno_scope,
            g.reno_start_date,
            g.reno_end_date,
            g.target_sale_price,
            g.list_date,
            g.sale_contract_date,
            g.sale_close_date,
            g.sale_price,
            g.loan_payoff,
            g.est_sell_closing_costs,
            g.other_costs,
            g.notes,
            g.funding_alert_sent_at,
            g.created_at,
            g.updated_at,
            g.sale_splits,
            g.reno_spent,
            g.cash_to_close_calc,
            g.cash_to_close_exact,
            g.sale_price_used,
            g.total_cash_in,
            g.reno_remaining,
            g.reno_pct,
            g.all_in_cost,
            g.total_budget,
            g.profit,
            g.est_net_proceeds,
            g.stage_no,
            COALESCE(( SELECT sum(flips.num(x.value ->> 'amount'::text)) AS sum
                   FROM jsonb_array_elements(COALESCE(g.sale_splits, '[]'::jsonb)) x(value)
                  WHERE (x.value ->> 'basis'::text) = 'fixed'::text), 0::numeric) AS split_fixed,
            COALESCE(( SELECT sum(flips.num(x.value ->> 'pct'::text)) AS sum
                   FROM jsonb_array_elements(COALESCE(g.sale_splits, '[]'::jsonb)) x(value)
                  WHERE (x.value ->> 'basis'::text) = 'sale'::text), 0::numeric) / 100.0 * COALESCE(g.sale_price_used, 0::numeric) AS split_sale,
            COALESCE(( SELECT sum(flips.num(x.value ->> 'pct'::text)) AS sum
                   FROM jsonb_array_elements(COALESCE(g.sale_splits, '[]'::jsonb)) x(value)
                  WHERE (x.value ->> 'basis'::text) = 'profit'::text), 0::numeric) / 100.0 AS split_profit_pct
           FROM g
        )
 SELECT id,
    address,
    stage,
    purchase_price,
    purchase_close_date,
    loan_amount,
    lender,
    earnest_money_paid,
    est_buy_closing_costs,
    cash_to_close,
    funded,
    reno_scope,
    reno_start_date,
    reno_end_date,
    target_sale_price,
    list_date,
    sale_contract_date,
    sale_close_date,
    sale_price,
    loan_payoff,
    est_sell_closing_costs,
    other_costs,
    notes,
    funding_alert_sent_at,
    created_at,
    updated_at,
    sale_splits,
    reno_spent,
    cash_to_close_calc,
    cash_to_close_exact,
    sale_price_used,
    total_cash_in,
    reno_remaining,
    reno_pct,
    all_in_cost,
    total_budget,
    profit,
    est_net_proceeds,
    stage_no,
    split_fixed,
    split_sale,
    split_profit_pct,
    profit - split_fixed - split_sale AS profit_before_shares,
        CASE
            WHEN (profit - split_fixed - split_sale) > 0::numeric THEN round((profit - split_fixed - split_sale) * split_profit_pct, 2)
            ELSE 0::numeric
        END AS split_profit,
    profit - split_fixed - split_sale -
        CASE
            WHEN (profit - split_fixed - split_sale) > 0::numeric THEN round((profit - split_fixed - split_sale) * split_profit_pct, 2)
            ELSE 0::numeric
        END AS net_profit,
    sale_splits IS NOT NULL AS splits_known,
    ( SELECT COALESCE(jsonb_agg(x.value || jsonb_build_object('dollars',
                CASE x.value ->> 'basis'::text
                    WHEN 'fixed'::text THEN COALESCE(flips.num(x.value ->> 'amount'::text), 0::numeric)
                    WHEN 'sale'::text THEN round(COALESCE(flips.num(x.value ->> 'pct'::text), 0::numeric) / 100.0 * COALESCE(s.sale_price_used, 0::numeric), 2)
                    WHEN 'profit'::text THEN
                    CASE
                        WHEN (s.profit - s.split_fixed - s.split_sale) > 0::numeric THEN round(COALESCE(flips.num(x.value ->> 'pct'::text), 0::numeric) / 100.0 * (s.profit - s.split_fixed - s.split_sale), 2)
                        ELSE 0::numeric
                    END
                    ELSE NULL::numeric
                END)), '[]'::jsonb) AS "coalesce"
           FROM jsonb_array_elements(COALESCE(s.sale_splits, '[]'::jsonb)) x(value)) AS splits_detail
   FROM s;

create or replace view flips.dashboard with (security_invoker = true) as
 SELECT c.id,
    c.address,
    c.stage,
    c.stage_no,
        CASE
            WHEN c.stage = 'Under Contract'::text THEN 'Under contract'::text
            WHEN c.stage = ANY (ARRAY['Closed'::text, 'Make-Ready'::text, 'Listed As-Is'::text]) THEN 'Owned: make-ready + as-is'::text
            WHEN c.stage = 'Renovating'::text THEN 'In renovation'::text
            WHEN c.stage = 'Listed'::text THEN 'Listed after reno'::text
            WHEN c.stage = 'Sale Pending'::text THEN 'Sale pending'::text
            ELSE 'Sold'::text
        END AS stage_group,
    c.purchase_price,
    c.purchase_close_date,
    c.loan_amount,
    c.lender,
    c.earnest_money_paid,
    c.est_buy_closing_costs,
    c.cash_to_close_calc AS cash_to_close,
    c.cash_to_close_exact,
    c.funded,
    c.purchase_close_date - CURRENT_DATE AS days_to_purchase_close,
        CASE
            WHEN c.stage = 'Under Contract'::text AND COALESCE(c.funded, false) = false AND (c.purchase_close_date - CURRENT_DATE) <= 7 THEN 'red'::text
            WHEN c.stage = 'Under Contract'::text AND COALESCE(c.funded, false) = false AND (c.purchase_close_date - CURRENT_DATE) <= 14 THEN 'amber'::text
            ELSE NULL::text
        END AS closing_flag,
    c.reno_scope,
    c.reno_spent,
    c.reno_remaining,
    c.reno_pct,
    c.reno_start_date,
    c.reno_end_date,
    GREATEST(c.reno_spent - COALESCE(c.reno_scope, 0::numeric), 0::numeric) AS reno_over,
    c.target_sale_price,
    c.list_date,
    c.sale_contract_date,
    c.sale_close_date,
    c.sale_price,
    c.sale_price_used,
    c.loan_payoff,
    c.est_sell_closing_costs,
    c.other_costs,
    c.est_net_proceeds,
    c.total_cash_in,
    c.all_in_cost,
    c.total_budget,
    c.profit_before_shares AS gross_profit,
    c.net_profit AS profit,
    c.splits_known,
    c.splits_detail,
    c.split_profit AS splits_total,
    c.split_fixed + c.split_sale AS sale_deductions,
    c.profit AS profit_before_fees,
    c.stage = 'Sold'::text AS profit_is_actual,
    c.created_at AS under_contract_date,
    c.notes,
    c.updated_at,
    prev.projected_profit AS prev_profit,
    prev.taken_at AS prev_profit_at,
        CASE
            WHEN prev.projected_profit IS NOT NULL THEN c.net_profit - prev.projected_profit
            ELSE NULL::numeric
        END AS profit_change,
    lu.received_at AS last_update_at,
    lu.note AS last_update_note,
        CASE
            WHEN (c.stage = ANY (ARRAY['Closed'::text, 'Make-Ready'::text])) AND c.purchase_close_date IS NOT NULL AND c.list_date IS NULL THEN CURRENT_DATE - c.purchase_close_date
            WHEN c.stage = 'Listed As-Is'::text AND c.list_date IS NOT NULL THEN CURRENT_DATE - c.list_date
            WHEN c.stage = 'Renovating'::text AND c.reno_start_date IS NOT NULL THEN CURRENT_DATE - c.reno_start_date
            WHEN c.stage = 'Listed'::text AND c.list_date IS NOT NULL THEN CURRENT_DATE - c.list_date
            ELSE NULL::integer
        END AS phase_day,
        CASE
            WHEN (c.stage = ANY (ARRAY['Closed'::text, 'Make-Ready'::text])) AND c.list_date IS NULL THEN 10
            WHEN c.stage = 'Listed As-Is'::text THEN 30
            WHEN c.stage = 'Renovating'::text THEN COALESCE(c.reno_end_date - c.reno_start_date, 60)
            ELSE NULL::integer
        END AS phase_target_days,
        CASE
            WHEN (c.stage = ANY (ARRAY['Closed'::text, 'Make-Ready'::text])) AND c.list_date IS NULL THEN c.purchase_close_date + 10
            WHEN c.stage = 'Listed As-Is'::text THEN c.list_date + 30
            WHEN c.stage = 'Renovating'::text THEN COALESCE(c.reno_end_date, c.reno_start_date + 60)
            ELSE NULL::date
        END AS phase_due
   FROM flips.house_calc c
     LEFT JOIN LATERAL ( SELECT s.projected_profit,
            s.taken_at
           FROM flips.snapshots s
          WHERE s.house_id = c.id AND s.projected_profit IS DISTINCT FROM c.net_profit
          ORDER BY s.taken_at DESC
         LIMIT 1) prev ON true
     LEFT JOIN LATERAL ( SELECT u.received_at,
            x.value ->> 'note'::text AS note
           FROM flips.updates u
             CROSS JOIN LATERAL jsonb_array_elements(COALESCE(u.parsed -> 'houses'::text, '[]'::jsonb)) x(value)
          WHERE (u.status = ANY (ARRAY['parsed'::text, 'parsed_ai'::text])) AND u.source_email_id !~~ 'manual-%'::text AND flips.find_house(x.value ->> 'address'::text) = c.id AND NULLIF(btrim(x.value ->> 'note'::text), ''::text) IS NOT NULL
          ORDER BY u.received_at DESC
         LIMIT 1) lu ON true;

create or replace view flips.gaps with (security_invoker = true) as
 WITH h AS (
         SELECT house_calc.id,
            house_calc.address,
            house_calc.stage,
            house_calc.purchase_price,
            house_calc.purchase_close_date,
            house_calc.loan_amount,
            house_calc.lender,
            house_calc.earnest_money_paid,
            house_calc.est_buy_closing_costs,
            house_calc.cash_to_close,
            house_calc.funded,
            house_calc.reno_scope,
            house_calc.reno_start_date,
            house_calc.reno_end_date,
            house_calc.target_sale_price,
            house_calc.list_date,
            house_calc.sale_contract_date,
            house_calc.sale_close_date,
            house_calc.sale_price,
            house_calc.loan_payoff,
            house_calc.est_sell_closing_costs,
            house_calc.other_costs,
            house_calc.notes,
            house_calc.funding_alert_sent_at,
            house_calc.created_at,
            house_calc.updated_at,
            house_calc.sale_splits,
            house_calc.reno_spent,
            house_calc.cash_to_close_calc,
            house_calc.cash_to_close_exact,
            house_calc.sale_price_used,
            house_calc.total_cash_in,
            house_calc.reno_remaining,
            house_calc.reno_pct,
            house_calc.all_in_cost,
            house_calc.total_budget,
            house_calc.profit,
            house_calc.est_net_proceeds,
            house_calc.stage_no,
            house_calc.split_fixed,
            house_calc.split_sale,
            house_calc.split_profit_pct,
            house_calc.profit_before_shares,
            house_calc.split_profit,
            house_calc.net_profit,
            house_calc.splits_known,
            house_calc.splits_detail
           FROM flips.house_calc
        ), f AS (
         SELECT h_1.id,
            h_1.address,
            h_1.stage,
            x.field,
            x.why
           FROM h h_1
             CROSS JOIN LATERAL ( VALUES ('purchase_price'::text,h_1.purchase_price IS NULL,'needed for every number'::text), ('purchase_close_date'::text,h_1.purchase_close_date IS NULL,'drives the closing countdown and cash schedule'::text), ('funded'::text,h_1.stage = 'Under Contract'::text AND h_1.funded IS NULL,'true/false: is the cash to close in place?'::text), ('loan_amount'::text,h_1.stage <> 'Sold'::text AND h_1.loan_amount IS NULL,'loan amount, or 0 if it is a cash buy'::text), ('est_buy_closing_costs'::text,h_1.est_buy_closing_costs IS NULL,'buy-side closing costs (0 if none)'::text), ('reno_scope'::text,h_1.stage <> 'Sold'::text AND h_1.reno_scope IS NULL,'reno budget; without it there is no over/under-budget check'::text), ('reno_start_date'::text,h_1.stage = 'Renovating'::text AND h_1.reno_start_date IS NULL,'spreads the remaining reno budget over the cash schedule'::text), ('reno_end_date'::text,h_1.stage = 'Renovating'::text AND h_1.reno_end_date IS NULL,'planned reno completion date'::text), ('target_sale_price'::text,h_1.stage <> 'Sold'::text AND h_1.target_sale_price IS NULL,'expected sale or list price; without it profit is blank'::text), ('list_date'::text,(h_1.stage = ANY (ARRAY['Listed As-Is'::text, 'Listed'::text, 'Sale Pending'::text])) AND h_1.list_date IS NULL,'date it went on the market'::text), ('sale_contract_date'::text,h_1.stage = 'Sale Pending'::text AND h_1.sale_contract_date IS NULL,'date the sale went under contract'::text), ('sale_close_date'::text,(h_1.stage = ANY (ARRAY['Sale Pending'::text, 'Sold'::text])) AND h_1.sale_close_date IS NULL,'sale closing date'::text), ('sale_price'::text,h_1.stage = 'Sold'::text AND h_1.sale_price IS NULL,'final sale price'::text), ('est_sell_closing_costs'::text,(h_1.stage = ANY (ARRAY['Sale Pending'::text, 'Sold'::text])) AND h_1.est_sell_closing_costs IS NULL,'seller title/closing fees (not commissions)'::text), ('loan_payoff'::text,(h_1.stage = ANY (ARRAY['Sale Pending'::text, 'Sold'::text])) AND h_1.loan_payoff IS NULL AND COALESCE(h_1.loan_amount, 0::numeric) > 0::numeric AND COALESCE(h_1.lender, ''::text) !~~* 'rising tide%'::text,'loan payoff at sale'::text), ('sale_splits'::text,h_1.sale_splits IS NULL,'who takes what from the sale'::text), ('stage'::text,(h_1.stage = ANY (ARRAY['Closed'::text, 'Make-Ready'::text])) AND h_1.list_date IS NOT NULL,'list date is set but the stage is still make-ready: is it Listed As-Is?'::text), ('sale_close_date'::text,h_1.stage <> 'Sold'::text AND h_1.sale_close_date < CURRENT_DATE,'sale closing date has passed: did it sell, move, or fall through? (send "clear":["sale_close_date","sale_contract_date"] if it fell through)'::text)) x(field, missing, why)
          WHERE x.missing
        )
 SELECT id,
    address,
    stage,
    stage_no,
    COALESCE(( SELECT jsonb_agg(jsonb_build_object('field', f.field, 'why', f.why)) AS jsonb_agg
           FROM f
          WHERE f.id = h.id), '[]'::jsonb) AS missing,
    ( SELECT count(*) AS count
           FROM f
          WHERE f.id = h.id) AS missing_count
   FROM h;

create or replace view flips.house_history with (security_invoker = true) as
 SELECT h.id AS house_id,
    u.received_at,
        CASE
            WHEN u.source_email_id ~~ 'manual-%'::text THEN 'manual'::text
            ELSE u.status
        END AS status,
    COALESCE(NULLIF(btrim(x.value ->> 'note'::text), ''::text), 'fields updated'::text) AS note,
    x.value AS fields
   FROM flips.houses h
     JOIN flips.updates u ON u.status = ANY (ARRAY['parsed'::text, 'parsed_ai'::text])
     CROSS JOIN LATERAL jsonb_array_elements(COALESCE(u.parsed -> 'houses'::text, '[]'::jsonb)) x(value)
  WHERE flips.find_house(x.value ->> 'address'::text) = h.id;

-- Data: 216 Oneal is listed as-is at $150K (Rob 10/16); 3241 Birch's sale fell through 10/23.
update flips.houses set as_is_price = 150000 where address = '216 Oneal' and as_is_price is null;
update flips.houses set sale_contract_date = null, sale_close_date = null where address = '3241 Birch' and stage <> 'Sale Pending';
delete from flips.costs where source = 'quickbooks' and (qb_txn_id like 'invNone%' or (amount = 0 and qb_txn_id not like 'rc%'));

-- Profit changes from these fixes are corrections, not news: restart the comparison point.
delete from flips.snapshots;
select flips.take_snapshot();
