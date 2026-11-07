import json, re, sys, collections
d = json.load(open(sys.argv[1]))['quickbooks_response']
# Optional 3rd arg: JSON {invoice id: house} for parent-billed ("3F Homes LLC") invoices whose lines have no address memo.
# Build it from the invoice's LinkedTxn ReimburseCharge ids and the houses those charges were pending under.
parent_map = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else {}
lines = []
def walk(rows):
    for r in rows:
        if r.get('type') == 'Data' and r['ColData'][1].get('id'):  # rows without a transaction id are section totals
            c = r['ColData']
            lines.append(dict(date=c[0]['value'], type=c[1]['value'], tid=c[1].get('id'), doc=c[2]['value'],
                              cust=c[3]['value'], memo=c[4]['value'], amt=float(c[5]['value'] or 0)))
        if 'Rows' in r: walk(r['Rows'].get('Row', []))
walk(d['Rows']['Row'])
print('lines', len(lines), 'types', collections.Counter(l['type'] for l in lines), file=sys.stderr)
mk = re.compile(r'^\d+(\.\d+)?% markup( for (.*))?$', re.I)
by = collections.OrderedDict()
for l in lines: by.setdefault(l['tid'], []).append(l)
def vendor(m):
    if not m: return None
    if re.search(r'home depot', m, re.I): return 'Home Depot'
    if re.search(r"lowe'?s", m, re.I): return "Lowe's"
    parts = [p.strip() for p in m.split(' - ')]
    keep = [p for p in parts if p and not re.match(r'^\d', p) and p.lower() != '3f homes' and not re.match(r'^ck\b', p, re.I)]
    return keep[0] if keep else None
rows = []
for tid, ls in by.items():
    base = [l for l in ls if not mk.match(l['memo'] or '')]
    marks = [l for l in ls if mk.match(l['memo'] or '')]
    groups = [dict(l=l, amt=l['amt']) for l in base]
    for m in marks:
        target = (mk.match(m['memo']).group(3) or '').strip()
        g = next((g for g in groups if (g['l']['memo'] or '').strip() == target and not g.get('mk')), None)
        if g: g['amt'] += m['amt']; g['mk'] = 1
        else: groups.append(dict(l=m, amt=m['amt']))
    groups = [g for g in groups if round(g['amt'], 2) != 0]  # zeroed-out lines (voided items) carry no cost
    for i, g in enumerate(groups):
        l = g['l']; house = l['cust'].split(':')[1].strip() if ':' in l['cust'] else l['cust']
        # Billed to the parent "3F Homes LLC" instead of the house job: the memo starts with the address.
        if ':' not in l['cust'] and re.match(r'^\d+\s', (l['memo'] or '')):
            house = l['memo'].split(' - ')[0].strip()
        elif ':' not in l['cust'] and tid in parent_map:
            house = parent_map[tid]  # no address memo: house comes from the charges the invoice links to
        elif ':' not in l['cust']:
            print(f'WARNING: parent-billed invoice {tid} line has no house; pass it in the parent map', file=sys.stderr)
        rows.append(dict(qb_txn_id=f"inv{tid}-g{i+1}", qb_doc_type=f"{l['type']} {l['doc']}".strip(), qb_customer=house,
                         txn_date=l['date'], vendor=vendor(l['memo']), memo=l['memo'] or None, amount=round(g['amt'], 2)))
print('rows', len(rows), 'gl total', round(sum(l['amt'] for l in lines), 2), 'rows total', round(sum(r['amount'] for r in rows), 2), file=sys.stderr)
tot = collections.defaultdict(float)
for r in rows: tot[r['qb_customer']] += r['amount']
for k, v in sorted(tot.items()): print(f'  {k}: {v:,.2f}', file=sys.stderr)
json.dump(rows, open(sys.argv[2], 'w'))
