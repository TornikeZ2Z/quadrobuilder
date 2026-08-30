"""Row-level export for the client-side dashboard."""
import json, os, sys, duckdb
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass
con = duckdb.connect('data/processed/quadro.duckdb')
ASOF = '2026-08-30'

lines = con.execute("""
SELECT strftime(s.date,'%Y-%m-%d') AS d, ISODOW(s.date) AS w,
       s.channel AS ch, s.barcode AS b, s.product AS p,
       -- 17 B2B lines carry no receipt number; group those by customer+day so the
       -- receipt count and average basket stay meaningful instead of collapsing to one.
       CASE WHEN s.receipt IS NOT NULL THEN CAST(s.receipt AS VARCHAR)
            ELSE 'u:'||COALESCE(s.company,'?')||':'||strftime(s.date,'%Y-%m-%d') END AS r,
       s.rev_qty AS q, ROUND(s.rev_value,2) AS v,
       s.is_return AS ret, ROUND(s.line_value,2) AS lv,
       COALESCE(st.category,'—') AS c,
       COALESCE(st.supplier,'—') AS sup,
       COALESCE(ROUND(st.unit_cost,4),0) AS u,
       CASE WHEN st.barcode IS NULL THEN 1 ELSE 0 END AS nocost
FROM sales s LEFT JOIN stock st USING(barcode)
ORDER BY s.date
""").df()
print('cost coverage by channel:')
print(con.execute("""
SELECT s.channel, COUNT(*) lines,
       SUM(CASE WHEN st.barcode IS NULL THEN 1 ELSE 0 END) AS no_cost,
       ROUND(SUM(CASE WHEN st.barcode IS NULL THEN s.rev_value ELSE 0 END),2) AS rev_without_cost
FROM sales s LEFT JOIN stock st USING(barcode) GROUP BY 1""").df().to_string(index=False))

stock = con.execute("""
SELECT st.barcode AS b, st.product AS p, COALESCE(st.category,'—') AS c,
       COALESCE(st.supplier,'—') AS s, st.qty_on_hand AS q,
       ROUND(st.unit_cost,4) AS u, ROUND(st.total_cost,2) AS t,
       -- opening + everything ever received: the most that can ever have sat on the
       -- shelf, since Optimo's export carries no dated goods receipts.
       COALESCE(m.open_qty,0) + COALESCE(m.qty_in,0) AS mx,
       COALESCE(m.qty_in,0) AS rin, COALESCE(m.qty_out,0) AS rout
FROM stock st LEFT JOIN movement m USING(barcode)""").df()

optimo = con.execute("""
SELECT strftime(date,'%Y-%m-%d') AS d, revenue AS rev, markup AS mk, txns AS t
FROM daily_stats WHERE revenue>0 OR txns>0 ORDER BY date""").df()

con.close()
out = {"as_of": ASOF,
       "lines": lines.to_dict('records'),
       "stock": stock.to_dict('records'),
       "optimo_daily": optimo.to_dict('records')}
json.dump(out, open('data/processed/dashboard.json','w',encoding='utf-8'),
          ensure_ascii=False, separators=(',',':'), default=str)
print(f"\nlines={len(lines)} stock={len(stock)} optimo_days={len(optimo)} "
      f"-> {os.path.getsize('data/processed/dashboard.json')/1024:.0f} KB")
