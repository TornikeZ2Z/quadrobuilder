"""Compute dashboard metrics -> data/processed/dashboard.json"""
import json, sys, duckdb, pandas as pd
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass

con = duckdb.connect('data/processed/quadro.duckdb')
q = lambda s: con.execute(s).df()
ASOF = '2026-08-30'
out = {"as_of": ASOF}

# ---- KPIs ----
k = q(f"""
WITH r AS (SELECT * FROM sales_retail)
SELECT ROUND(SUM(line_value),2) gross,
       ROUND(SUM(CASE WHEN is_return THEN line_value ELSE 0 END),2) AS returns_val,
       ROUND(SUM(net_value),2) net_rev,
       COUNT(DISTINCT receipt) receipts,
       COUNT(DISTINCT barcode) skus_sold,
       ROUND(SUM(net_qty),0) units,
       MIN(date)::DATE first_sale
FROM r""").iloc[0]
m = q("""SELECT ROUND(SUM(s.net_qty*st.unit_cost),2) cogs
         FROM sales_retail s LEFT JOIN stock st USING(barcode)""").iloc[0]
st = q("SELECT COUNT(*) skus, SUM(CASE WHEN qty_on_hand>0 THEN 1 ELSE 0 END) in_stock, ROUND(SUM(total_cost),2) cost_value FROM stock").iloc[0]
dead = q("""SELECT COUNT(*) skus, ROUND(SUM(total_cost),2) capital FROM stock
            WHERE qty_on_hand>0 AND barcode NOT IN (SELECT DISTINCT barcode FROM sales_retail)""").iloc[0]
days = (pd.Timestamp(ASOF) - pd.Timestamp(k.first_sale)).days + 1
out["kpi"] = {
 "gross": float(k.gross), "returns": float(k.returns_val), "net_rev": float(k.net_rev),
 "receipts": int(k.receipts), "units": float(k.units), "skus_sold": int(k.skus_sold),
 "cogs": float(m.cogs), "margin": round(float(k.net_rev)-float(m.cogs),2),
 "margin_pct": round(100*(float(k.net_rev)-float(m.cogs))/float(k.net_rev),1),
 "avg_receipt": round(float(k.net_rev)/int(k.receipts),2),
 "return_rate": round(100*float(k.returns_val)/float(k.gross),1),
 "stock_skus": int(st.skus), "stock_in": int(st.in_stock), "stock_value": float(st.cost_value),
 "dead_skus": int(dead.skus), "dead_capital": float(dead.capital),
 "dead_pct": round(100*float(dead.capital)/float(st.cost_value),1),
 "first_sale": str(k.first_sale), "days": days, "weeks": round(days/7,1),
}

# ---- weekly revenue (retail) ----
out["weekly"] = q("""
 SELECT DATE_TRUNC('week', date)::DATE AS wk,
        ROUND(SUM(net_value),2) rev, COUNT(DISTINCT receipt) receipts
 FROM sales_retail GROUP BY 1 ORDER BY 1""").assign(wk=lambda d: d.wk.astype(str)).to_dict('records')

# ---- top products by revenue ----
out["top_revenue"] = q("""
SELECT ANY_VALUE(s.product) product, s.barcode,
       ROUND(SUM(s.net_value),2) rev, SUM(s.net_qty) units,
       COUNT(DISTINCT s.receipt) txns,
       ROUND(SUM(s.net_value - s.net_qty*st.unit_cost),2) margin,
       ROUND(100*SUM(s.net_value - s.net_qty*st.unit_cost)/NULLIF(SUM(s.net_value),0),1) margin_pct,
       ANY_VALUE(st.category) category, ANY_VALUE(st.qty_on_hand) on_hand
FROM sales_retail s LEFT JOIN stock st USING(barcode)
GROUP BY s.barcode HAVING SUM(s.net_value)>0
ORDER BY rev DESC LIMIT 15""").to_dict('records')

# ---- velocity + days of cover (recent 60d) ----
vel = q(f"""
WITH recent AS (
  SELECT barcode, SUM(net_qty) u60 FROM sales_retail
  WHERE date >= DATE '{ASOF}' - INTERVAL 60 DAY GROUP BY 1),
alltime AS (
  SELECT barcode, ANY_VALUE(product) product, SUM(net_qty) units,
         COUNT(DISTINCT receipt) txns, SUM(net_value) rev
  FROM sales_retail GROUP BY 1)
SELECT a.product, a.units, a.txns, ROUND(a.rev,2) rev,
       COALESCE(r.u60,0) u60,
       ROUND(COALESCE(r.u60,0)/60.0*7,2) units_per_week,
       st.qty_on_hand on_hand,
       CASE WHEN COALESCE(r.u60,0)>0
            THEN ROUND(st.qty_on_hand/(r.u60/60.0),0) END days_cover,
       st.category, ROUND(st.unit_cost,2) unit_cost
FROM alltime a LEFT JOIN recent r USING(barcode) JOIN stock st USING(barcode)
WHERE a.txns>=3
ORDER BY units_per_week DESC""")
out["velocity"] = vel.head(15).where(pd.notna(vel.head(15)), None).to_dict('records')
rr = vel[(vel.days_cover.notna()) & (vel.days_cover < 21)].sort_values('rev', ascending=False)
out["reorder"] = rr.head(12).where(pd.notna(rr.head(12)), None).to_dict('records')

# ---- dead stock ----
out["dead_stock"] = q("""
SELECT product, category, supplier, qty_on_hand, ROUND(unit_cost,2) unit_cost, ROUND(total_cost,2) capital
FROM stock WHERE qty_on_hand>0 AND barcode NOT IN (SELECT DISTINCT barcode FROM sales_retail)
ORDER BY total_cost DESC LIMIT 12""").to_dict('records')

# ---- category performance ----
out["categories"] = q("""
SELECT st.category,
       ROUND(SUM(s.net_value),2) rev, SUM(s.net_qty) units,
       ROUND(SUM(s.net_value - s.net_qty*st.unit_cost),2) margin,
       ROUND(100*SUM(s.net_value - s.net_qty*st.unit_cost)/NULLIF(SUM(s.net_value),0),1) margin_pct,
       COUNT(DISTINCT s.barcode) skus
FROM sales_retail s JOIN stock st USING(barcode)
GROUP BY 1 HAVING SUM(s.net_value)>0 ORDER BY rev DESC LIMIT 10""").to_dict('records')

# ---- day of week / hour ----
out["dow"] = q("""SELECT ISODOW(date) d, ROUND(SUM(net_value),2) rev, COUNT(DISTINCT receipt) receipts
                  FROM sales_retail GROUP BY 1 ORDER BY 1""").to_dict('records')
out["hour"] = q("""SELECT HOUR(date) h, ROUND(SUM(net_value),2) rev, COUNT(DISTINCT receipt) receipts
                   FROM sales_retail GROUP BY 1 ORDER BY 1""").to_dict('records')

# ---- payment + staff ----
out["payment"] = q("""SELECT paymethod, ROUND(SUM(net_value),2) rev, COUNT(DISTINCT receipt) receipts
                      FROM sales_retail GROUP BY 1 ORDER BY rev DESC""").to_dict('records')
out["staff"] = q("""SELECT staff, ROUND(SUM(net_value),2) rev, COUNT(DISTINCT receipt) receipts,
                    ROUND(SUM(net_value)/COUNT(DISTINCT receipt),2) avg_receipt
                    FROM sales_retail GROUP BY 1 ORDER BY rev DESC""").to_dict('records')

# ---- B2B ----
out["b2b"] = {
 "by_status": q("SELECT status, COUNT(*) lines, ROUND(SUM(line_value),2) AS val FROM sales_entity GROUP BY 1 ORDER BY val DESC").to_dict('records'),
 "by_company": q("""SELECT company, taxid, COUNT(*) lines, ROUND(SUM(line_value),2) AS val,
                    ROUND(SUM(CASE WHEN status='გაუქმებული' THEN line_value ELSE 0 END),2) AS cancelled
                    FROM sales_entity GROUP BY 1,2 ORDER BY val DESC""").to_dict('records'),
}
con.close()
json.dump(out, open('data/processed/dashboard.json','w',encoding='utf-8'), ensure_ascii=False, indent=1, default=str)
print('KPI:', json.dumps(out['kpi'], ensure_ascii=False, indent=1))
print('\nweeks:', len(out['weekly']), '| categories:', len(out['categories']), '| reorder:', len(out['reorder']), '| dead:', len(out['dead_stock']))
