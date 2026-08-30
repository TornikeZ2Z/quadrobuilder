# QuadroBuilder — Shelf & Till

Sales, velocity and dead-stock analysis for შპს ქუადრო ბილდერი, rebuilt from
Optimo (dashboard.optimo.ge) Excel exports.

Published at <https://reporting.quadrobuilder.ge>.

## Rebuilding after a fresh export

1. Export from Optimo into `data/raw/` (not committed):
   - `sales_lines_retail.xlsx` — Transactions → საცალო → ˅ → პროდუქტები
   - `sales_lines_entity.xlsx` — Transactions → ი/პ → ˅ → პროდუქტები
   - `stock_on_hand.xlsx` — ნაშთები
   - `stock_movement.xlsx` — მარაგების მოძრაობა
   - `daily_statistics.xlsx` — სტატისტიკა → ზოგადი
2. `python scripts/build_warehouse.py` — loads into DuckDB
3. `python scripts/export_data.py` — row-level JSON
4. `python scripts/render.py` — writes `dashboard.html`
5. `cp dashboard.html docs/index.html && git commit -am "refresh" && git push`

Raw exports and the DuckDB file are gitignored — only the rendered page ships.
