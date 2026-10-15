-- 1) "Last update from Rob" only counts Rob's emails; manual fills (source_email_id 'manual-...') still show in history.
create or replace view flips.house_history with (security_invoker = true) as
select h.id as house_id, u.received_at, case when u.source_email_id like 'manual-%' then 'manual' else u.status end as status,
       coalesce(x->>'note', u.note) as note, x as fields
from flips.houses h
join flips.updates u on u.status in ('parsed','parsed_ai')
cross join lateral jsonb_array_elements(coalesce(u.parsed->'houses','[]'::jsonb)) x
where lower(trim(x->>'address')) = lower(h.address);

-- Restore Rob's latest note on houses touched by a manual fill.
update flips.houses h set notes = r.note
from (select distinct on (lower(trim(x->>'address'))) lower(trim(x->>'address')) addr, x->>'note' note
      from flips.updates u cross join lateral jsonb_array_elements(u.parsed->'houses') x
      where u.source_email_id not like 'manual-%' and u.status in ('parsed','parsed_ai') and nullif(x->>'note','') is not null
      order by lower(trim(x->>'address')), u.received_at desc) r
where lower(h.address) = r.addr;

-- 2) Charges Renovation Depot has billed to a 3F job but not invoiced yet (invoices go out Saturdays).
-- rows = [{qb_txn_id:'rc<ChargeId>', qb_customer, txn_date, vendor, memo, amount}] = the FULL current list;
-- charges that got invoiced since last run drop off here and come back as invoice lines.
create or replace function flips.replace_pending_charges(rows jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  delete from flips.costs where source = 'quickbooks' and qb_txn_id like 'rc%'
    and qb_txn_id not in (select r->>'qb_txn_id' from jsonb_array_elements(coalesce(rows,'[]')) r);
  insert into flips.costs(source, qb_txn_id, qb_doc_type, qb_customer, txn_date, vendor, memo, amount)
  select 'quickbooks', r->>'qb_txn_id', 'Not invoiced yet', r->>'qb_customer', flips.dt(r->>'txn_date'), r->>'vendor', r->>'memo', coalesce(flips.num(r->>'amount'),0)
  from jsonb_array_elements(coalesce(rows,'[]')) r
  on conflict (qb_txn_id) do update set qb_customer = excluded.qb_customer, txn_date = excluded.txn_date,
    vendor = excluded.vendor, memo = excluded.memo, amount = excluded.amount, updated_at = now();
  get diagnostics n = row_count;
  perform flips.rematch_costs();
  return jsonb_build_object('pending', n);
end $$;
revoke execute on function flips.replace_pending_charges(jsonb) from public, anon, authenticated;
