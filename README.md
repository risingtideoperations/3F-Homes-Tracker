# 3F Homes Flip Tracker

Read-only dashboard of every 3F Homes flip, from purchase contract to sale. Viewers: Rob (rashurst@live.com), Cullen (ccrowe@rtmhouses.com), Ryan (rmedo@rtmhouses.com).

## Pieces
- **Database:** Supabase project `csdsendpbnwycwhqwgbe`, schema `flips` (`sql/`). All math is in views: `dashboard`, `cash_schedule`, `summary`, `house_history`. Browser = select only, RLS limits rows to `flips.allowed_viewers`.
- **Page:** `web/index.html` (plain HTML/JS, supabase-js). Stored in `flips.site_files` and served by n8n workflow "3F Flips — Website" at https://risingtideoperations.app.n8n.cloud/webhook/3f-flips. Deploy a change: `python3 deploy_page.py` (needs `SUPABASE_ACCESS_TOKEN`).
- **Sign-in:** same `#k=` bookmark pattern as the Collections app. Each viewer has a personal key in `flips.viewer_keys`; entering your email on the page has n8n email your link from the ops Gmail. Supabase edge function `flips-login` swaps the key for a Supabase session (`verifyOtp`), so no project auth settings were changed. Revoke someone: delete their `viewer_keys` row (and `allowed_viewers`).
- **Feeds (n8n, 7 AM + 5 PM Central):**
  - "3F Flips — Rob email updates" (`50vLQnZUcYVFbDmG`): unread "3F UPDATE" mail from claudemastery@gmail.com / rob3fhome@gmail.com, JSON block -> `flips.apply_update()`. Haiku only when no valid JSON. Blank never overwrites. One-time unfunded-closing alert to Ryan + Cullen.
  - QuickBooks costs: Claude routine "3F Flips — QuickBooks pull (Meridian)" (`trig_011WZ1g7bAGTJBaayDCxa8xe`, 6:52 AM + 4:52 PM CT) reads Renovation Depot invoices to "3F Homes LLC:<house>" sub-customers changed since `sync_state.qb_last_run` via the Meridian connector -> `flips.upsert_qb_costs()` -> `flips.take_snapshot()`. Needs the Meridian + Supabase connectors attached in claude.ai Routines.
  - Backup: n8n "3F Flips — QuickBooks pull" (`wEjcUckQiC3mZtkw`, unpublished) does the same with an n8n QuickBooks OAuth credential, if one is ever connected.

## Rules baked in
- Cost = what Renovation Depot invoices 3F (expense + markup). Vendor bills are NOT counted: they are the same dollars before markup.
- QB -> house match is exact on house number + first street word. Anything else stays unmatched (`flips.costs.house_id is null`) until an exact match exists.
- Projected profit counts the larger of reno scope and reno spent (unspent budget is still a cost). Sold houses use actual spent.
