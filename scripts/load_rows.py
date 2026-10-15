import json, os, sys, urllib.request
rows = json.load(open(sys.argv[1]))
def q(sql):
    req = urllib.request.Request('https://api.supabase.com/v1/projects/csdsendpbnwycwhqwgbe/database/query',
        data=json.dumps({'query': sql}).encode(), headers={'Authorization': 'Bearer ' + os.environ['SUPABASE_ACCESS_TOKEN'], 'Content-Type': 'application/json'}, method='POST')
    return urllib.request.urlopen(req).read().decode()
last = None
# Batch on invoice boundaries: upsert_qb_costs drops stored lines of any invoice it touches that are missing from the batch.
batches, cur, prev = [], [], None
for r in rows:
    inv = r['qb_txn_id'].split('-')[0]
    if len(cur) >= 300 and inv != prev: batches.append(cur); cur = []
    cur.append(r); prev = inv
if cur: batches.append(cur)
for b in batches:
    j = json.dumps(b); assert '$j$' not in j
    last = q(f"select flips.upsert_qb_costs($j${j}$j$::jsonb) r")
print(last[:600])
print(q("insert into flips.sync_state(key,value,updated_at) values ('qb_last_run', to_char((now() - interval '10 minutes') at time zone 'UTC','YYYY-MM-DD\"T\"HH24:MI:SS\"+00:00\"'), now()) on conflict (key) do update set value=excluded.value, updated_at=now(); select flips.take_snapshot(); select count(*) n, sum(amount) total, count(*) filter (where house_id is null) unmatched from flips.costs;"))
