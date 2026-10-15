# 3F Homes Flip Tracker

Read-only dashboard of every 3F Homes flip, from purchase contract to sale. Viewers: Rob (rashurst@live.com), Cullen (ccrowe@rtmhouses.com), Ryan (rmedo@rtmhouses.com).

## Pieces
- **Database:** Supabase project `csdsendpbnwycwhqwgbe`, schema `flips` (`sql/`). All math is in views: `dashboard`, `cash_schedule`, `summary`, `house_history`. Browser = select only, RLS limits rows to `flips.allowed_viewers`.
- **Page:** `web/index.html` (plain HTML/JS, supabase-js). Stored in `flips.site_files` and served by n8n workflow "3F Flips — Website" at https://risingtideoperations.app.n8n.cloud/webhook/3f-flips. Deploy a change: `python3 deploy_page.py` (needs `SUPABASE_ACCESS_TOKEN`).
- **Sign-in:** same `#k=` bookmark pattern as the Collections app. Each viewer has a personal key in `flips.viewer_keys`; entering your email on the page has n8n email your link from the ops Gmail. Supabase edge function `flips-login` swaps the key for a Supabase session (`verifyOtp`), so no project auth settings were changed. Revoke someone: delete their `viewer_keys` row (and `allowed_viewers`).
- **Feeds (n8n, 7 AM + 5 PM Central):**
  - "3F Flips — Rob email updates" (`50vLQnZUcYVFbDmG`): unread "3F UPDATE" mail from claudemastery@gmail.com / rob3fhome@gmail.com, JSON block -> `flips.apply_update()`. Haiku only when no valid JSON. Blank never overwrites. One-time unfunded-closing alert to Ryan + Cullen.
  - QuickBooks costs (6:52 AM + 4:52 PM CT): a scheduled Claude run in the session that holds the Meridian QuickBooks connector.
    1. Meridian `query` for 3F invoices changed since `flips.sync_state.qb_last_run` (`SELECT * FROM Invoice WHERE CustomerRef IN (<3F job ids>) AND MetaData.LastUpdatedTime >= '<since>'`) to find the earliest TxnDate touched.
    2. Meridian `fetch_quickbooks_report` general_ledger, accounts 4001 (id 1) + 4002 Markup (id 49), the 3F job customers, from that date to today, `delivery: download`, columns tx_date, txn_type, doc_num, name, memo, subt_nat_amount. Download the JSON.
    3. `python3 -I scripts/gl_rows.py gl.json rows.json` folds each expense + its markup line into one cost row.
    4. `python3 -I scripts/load_rows.py rows.json` upserts in whole-invoice batches, rematches, snapshots, and advances `qb_last_run`.
    5. Charges billed to a 3F job but not invoiced yet (Renovation Depot invoices on Saturdays): Meridian `ReimburseCharge WHERE HasBeenInvoiced = false` -> `flips.replace_pending_charges()` (full list each run; rows `rc<Id>`, shown as "Not invoiced yet").
    First full backfill 10/15/2026: 1,242 rows, $1,116,002.44 (matches the QuickBooks GL to the penny).
  - Backup: n8n "3F Flips — QuickBooks pull" (`wEjcUckQiC3mZtkw`, unpublished) does the same through an n8n QuickBooks credential if one is ever connected.

## For Rob's Claude (read-only agent feed)
`GET https://risingtideoperations.app.n8n.cloud/webhook/3f-flips-gaps?k=<key>` returns every house, what the tracker has, what's missing (`flips.gaps`) and the QuickBooks jobs not in the tracker. Keys live in `flips.agent_keys` (service-only); delete a row to revoke. The same list is the page's **Missing info** tab.

## Rules baked in
- Cost = what Renovation Depot invoices 3F (expense + markup). Vendor bills are NOT counted: they are the same dollars before markup.
- QB -> house match is exact on house number + first street word. Anything else stays unmatched (`flips.costs.house_id is null`) until an exact match exists.
- `funded` can be unknown (null). Unknown still triggers the one-time 7-day alert.
- Manual fills are logged in `flips.updates` as `manual-...`; they show in history but never as "Last update from Rob".
- Projected profit counts the larger of reno scope and reno spent (unspent budget is still a cost). Sold houses use actual spent.
