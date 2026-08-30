# QuadroBuilder — Shelf & Till

Sales, velocity and dead-stock analysis for შპს ქუადრო ბილდერი, rebuilt from
Optimo (dashboard.optimo.ge) Excel exports.

Published at <https://reporting.quadrobuilder.ge>.

## Automatic refresh

`scripts/auto_export.mjs` drives the real Optimo UI in a persistent Chromium
profile, downloads the six reports, rebuilds the dashboard and pushes it.
No password is stored anywhere — the browser session is.

    node scripts/auto_export.mjs --login    # once: sign in, session is saved
    node scripts/auto_export.mjs            # a refresh on demand

It runs at logon via `Startup\QuadroBuilderRefresh.vbs` -> `scripts/daily_refresh.cmd`,
which refreshes once per day and logs to `logs/refresh.log`. When the Optimo session
eventually expires the run fails, pops a message, and re-running with `--login` fixes it.

Two things that will bite if you touch the script:
  - Do NOT set `channel:'chrome'`. Launching the installed Chrome while Chrome is
    already open makes the new process hand off to the running instance and exit,
    killing the context mid-download.
  - Do NOT call `download.failure()` before `saveAs()`. It blocks until the download
    settles and then reports the context as closed, breaking every export.

## Rebuilding by hand

1. Export from Optimo into `data/raw/` (not committed):
   - `sales_lines_retail.xlsx` — Transactions → საცალო → ˅ → პროდუქტები
   - `sales_lines_entity.xlsx` — Transactions → ი/პ → ˅ → პროდუქტები
   - `stock_on_hand.xlsx` — ნაშთები
   - `stock_movement.xlsx` — მარაგების მოძრაობა
   - `daily_statistics.xlsx` — სტატისტიკა → ზოგადი
   - `supplies_ledger.xlsx` — რეპორტები → მარაგები (per-movement ledger with a
     running balance; this is what gives the TRUE peak shelf level, since
     movement.qty_in also accumulates the restock from every cancelled sale)
2. `python scripts/build_warehouse.py` — loads into DuckDB
3. `python scripts/export_data.py` — row-level JSON
4. `python scripts/render.py` — writes `dashboard.html`
5. `cp dashboard.html docs/index.html && git commit -am "refresh" && git push`

Raw exports and the DuckDB file are gitignored — only the rendered page ships.
