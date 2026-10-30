-- Rob's 10/23 update asked to drop 308 Oregon St (contract cancelled) and used "605 Manchester Ln",
-- which created a duplicate row. apply_update now removes cancelled houses and matches address variants.
CREATE OR REPLACE FUNCTION flips.apply_update(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
        -- "605 Manchester Ln" vs "605 Manchester Dr": fall back to number + street when exactly one house matches.
        if hid is null then
          select min(id) into hid from flips.houses where flips.addr_key(address) = flips.addr_key(h->>'address')
          having count(*) = 1;
        end if;
        -- Cancelled contracts come off the tracker ("stage":"Cancelled", "remove":true, or a "remove from tracker" note).
        if h->>'stage' ilike 'cancel%' or h->>'remove' = 'true' or h->>'note' ilike '%remove from tracker%' then
          if hid is not null then
            delete from flips.snapshots where house_id = hid;
            delete from flips.costs where house_id = hid and source = 'rob';
            update flips.costs set house_id = null where house_id = hid;
            update flips.updates set house_id = null where house_id = hid;
            delete from flips.houses where id = hid;
            n := n + 1;
          end if;
          continue;
        end if;
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
    perform flips.apply_rob_costs(p);
  elsif st not in ('error') then
    st := 'unparsed';
  end if;

  insert into flips.updates(house_id, source_email_id, received_at, raw_text, parsed, note, status)
  values (case when array_length(ids,1) = 1 then ids[1] end, p->>'email_id',
          coalesce((p->>'received_at')::timestamptz, now()), p->>'raw_text', p->'parsed',
          coalesce(first_note, p->>'error'), st);
  perform flips.rematch_costs();
  return jsonb_build_object('ok', st in ('parsed','parsed_ai'), 'status', st, 'houses', n);
end $function$;
revoke execute on function flips.apply_update(jsonb) from public, anon, authenticated;

-- One-time cleanup of what that update left behind.
delete from flips.snapshots where house_id in (24, 25);
update flips.updates set house_id = null where house_id in (24, 25);
delete from flips.houses where id in (24, 25) and address in ('605 Manchester Ln', '308 Oregon St');
update flips.houses set address = '605 Manchester Ln', list_date = '2026-05-22', updated_at = now() where id = 20;
