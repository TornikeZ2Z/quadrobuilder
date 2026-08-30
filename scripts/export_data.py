"""Export row-level data for a client-side filterable dashboard."""
import json, sys, duckdb
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass

con = duckdb.connect('data/processed/quadro.duckdb')
ASOF = '2026-08-30'

lines = con.execute("""
SELECT strftime(s.date,'%Y-%m-%d') AS d,
       HOUR(s.date) AS h, ISODOW(s.date) AS w,
       s.receipt AS r, s.barcode AS b, s.product AS p,
       s.net_qty AS q, ROUND(s.net_value,2) AS v,
       s.staff AS sf, s.paymethod AS m,
       COALESCE(st.category,'—') AS c,
       COALESCE(ROUND(st.unit_cost,4),0) AS u
FROM sales_retail s LEFT JOIN stock st USING(barcode)
ORDER BY s.date
""").df().to_dict('records')

stock = con.execute("""
SELECT barcode AS b, product AS p, COALESCE(category,'—') AS c,
       COALESCE(supplier,'—') AS s, qty_on_hand AS q,
       ROUND(unit_cost,4) AS u, ROUND(total_cost,2) AS t
FROM stock
""").df().to_dict('records')

b2b = {
 "by_company": con.execute("""
   SELECT company, taxid, COUNT(*) AS lines, ROUND(SUM(line_value),2) AS val,
          ROUND(SUM(CASE WHEN status='გაუქმებული' THEN line_value ELSE 0 END),2) AS cancelled
   FROM sales_entity GROUP BY 1,2 ORDER BY val DESC""").df().to_dict('records'),
 "by_status": con.execute("""
   SELECT status, COUNT(*) AS lines, ROUND(SUM(line_value),2) AS val
   FROM sales_entity GROUP BY 1 ORDER BY val DESC""").df().to_dict('records'),
}
optimo = con.execute("SELECT ROUND(SUM(revenue),2) r, ROUND(SUM(markup),2) mk, SUM(txns) t FROM daily_stats").df().iloc[0]
con.close()

out = {"as_of": ASOF, "lines": lines, "stock": stock, "b2b": b2b,
       "optimo": {"revenue": float(optimo.r), "markup": float(optimo.mk), "txns": int(optimo.t)}}
json.dump(out, open('data/processed/dashboard.json','w',encoding='utf-8'),
          ensure_ascii=False, separators=(',',':'), default=str)
import os
print(f"lines={len(lines)} stock={len(stock)} -> {os.path.getsize('data/processed/dashboard.json')/1024:.0f} KB")
print("categories:", len(set(l['c'] for l in lines)))
