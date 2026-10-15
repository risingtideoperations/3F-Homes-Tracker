-- When did Rob's Claude last send anything (email or direct)? Shown in the page header.
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
           (select max(updated_at) from flips.sync_state)) as data_as_of,
  (select max(received_at) from flips.updates
     where status in ('parsed','parsed_ai') and source_email_id not like 'manual-%' and source_email_id not like 'api-ryan%'
       and coalesce(raw_text,'') not like 'Route check%') as last_rob_update_at;
