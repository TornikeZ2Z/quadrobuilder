"""Build DuckDB warehouse from Optimo exports.

Revenue model (verified against Optimo's own daily statistics to the lari):
  revenue = retail lines EXCLUDING those flagged returned
          + entity lines EXCLUDING those flagged cancelled
A returned retail line is the original sale re-flagged, so it is excluded,
not negated. Negating it double-counts the loss.
"""
import os, sys
import pandas as pd, duckdb
try: sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception: pass

RAW, OUT = "data/raw", "data/processed/quadro.duckdb"
os.makedirs("data/processed", exist_ok=True)
nb = lambda s: s.astype(str).str.strip().str.replace(r"\.0$", "", regex=True)

# retail
r = pd.read_excel(f"{RAW}/sales_lines_retail.xlsx")
r.columns = ["receipt","txn","status","paymethod","product","barcode","staff","serial","qty",
             "line_value","date","vat","modifier","extras","cash","cashless","bog","bog_int",
             "tbc","liberty","procredit","keepz","manual","other"]
r["date"] = pd.to_datetime(r["date"], format="%m/%d/%Y %H:%M:%S %z", utc=True).dt.tz_convert("Asia/Tbilisi")
r["barcode"] = nb(r["barcode"])
r["is_return"]  = r["status"].eq("დაბრუნებული")
r["counts"]     = ~r["is_return"]
r["rev_qty"]    = r["qty"].where(r["counts"], 0)
r["rev_value"]  = r["line_value"].where(r["counts"], 0)
r["channel"]    = "retail"
r["company"]    = None

# entity / B2B
e = pd.read_excel(f"{RAW}/sales_lines_entity.xlsx")
e.columns = ["receipt","product","barcode","company","taxid","txn","ctype","paymethod","paytype",
             "staff","status","qty","line_value","date","vat","modifier","extras"]
e["date"] = pd.to_datetime(e["date"], format="%m/%d/%Y %H:%M:%S %z", utc=True).dt.tz_convert("Asia/Tbilisi")
e["barcode"] = nb(e["barcode"])
e["is_return"] = False
e["counts"]    = ~e["status"].eq("გაუქმებული")
e["rev_qty"]   = e["qty"].where(e["counts"], 0)
e["rev_value"] = e["line_value"].where(e["counts"], 0)
e["channel"]   = "entity"
e["staff"]     = e["staff"].fillna("—")

s = pd.read_excel(f"{RAW}/stock_on_hand.xlsx")
s.columns = ["barcode","product","supplier","category","qty_on_hand","unit_cost","total_cost"]
s["barcode"] = nb(s["barcode"])

m = pd.read_excel(f"{RAW}/stock_movement.xlsx")
m.columns = ["barcode","product","supplier","type","open_qty","open_unit_cost","open_total_cost",
             "qty_in","qty_out","close_qty","close_unit_cost","close_total_cost"]
m["barcode"] = nb(m["barcode"])

cols = ["channel","date","receipt","barcode","product","staff","paymethod","status",
        "qty","line_value","rev_qty","rev_value","counts","is_return","company"]
sales = pd.concat([r.reindex(columns=cols), e.reindex(columns=cols)], ignore_index=True)
# Cancelled B2B lines are dropped entirely - not revenue, not reported anywhere.
before = len(sales)
sales = sales[~((sales.channel == "entity") & (~sales.counts))].reset_index(drop=True)
print(f"  dropped {before-len(sales)} cancelled B2B lines")

con = duckdb.connect(OUT)
for name, df in [("sales", sales), ("stock", s), ("movement", m)]:
    try: con.execute(f"DROP VIEW IF EXISTS {name}")
    except Exception: pass
    try: con.execute(f"DROP TABLE IF EXISTS {name}")
    except Exception: pass
    con.register("t", df); con.execute(f"CREATE TABLE {name} AS SELECT * FROM t"); con.unregister("t")
    print(f"  {name:<10} {len(df):>6,} rows")

# ---- per-movement stock ledger -------------------------------------------
# Carries a running balance per movement, so the TRUE peak shelf level is
# max(balance). movement.qty_in cannot give this: it also accumulates the
# restock from every cancelled sale, which is why the KUMTEL freezer read 36
# when it never held more than 6.
lg = pd.read_excel(f"{RAW}/supplies_ledger.xlsx")
lg.columns = ["barcode","product","supplier","category","status","qty_before",
              "delta","balance","recv_date","post_date"]
lg["barcode"] = nb(lg["barcode"])
lg["post"] = pd.to_datetime(lg["post_date"], format="%m/%d/%Y %H:%M:%S %z", utc=True)
lg = lg.sort_values("post")
con.execute("DROP TABLE IF EXISTS ledger")
con.register("t", lg); con.execute("CREATE TABLE ledger AS SELECT * FROM t"); con.unregister("t")
print(f"  {'ledger':<10} {len(lg):>6,} rows")
print("    ledger tie-out to stock on hand:")
print(con.execute("""
  SELECT COUNT(*) AS skus,
         SUM(CASE WHEN ABS(l.last_bal - st.qty_on_hand) < 0.001 THEN 1 ELSE 0 END) AS ties
  FROM (SELECT barcode, LAST(balance ORDER BY post) AS last_bal FROM ledger GROUP BY 1) l
  JOIN stock st USING(barcode)""").df().to_string(index=False))

xl = pd.ExcelFile(f"{RAW}/daily_statistics.xlsx")
mp = {"შემოსავალი":"revenue","ფასნამატი":"markup","ტრანზაქციები":"txns","საშუალო ქვითარი":"avg_receipt"}
d = None
for sh in xl.sheet_names:
    t = xl.parse(sh); t.columns = ["date", mp[sh]]
    t["date"] = pd.to_datetime(t["date"]).dt.date
    d = t if d is None else d.merge(t, on="date", how="outer")
con.execute("DROP TABLE IF EXISTS daily_stats")
con.register("t", d); con.execute("CREATE TABLE daily_stats AS SELECT * FROM t"); con.unregister("t")
print(f"  {'daily_stats':<10} {len(d):>6,} rows")

print("\n=== RECONCILIATION vs Optimo ===")
print(con.execute("""
SELECT ROUND(SUM(rev_value),2) AS mine,
       (SELECT ROUND(SUM(revenue),2) FROM daily_stats) AS optimo,
       ROUND(SUM(rev_value) - (SELECT SUM(revenue) FROM daily_stats),2) AS diff
FROM sales""").df().to_string(index=False))
print(con.execute("""
SELECT channel, ROUND(SUM(rev_value),2) AS revenue, SUM(CASE WHEN counts THEN 1 ELSE 0 END) AS live_lines,
       SUM(CASE WHEN NOT counts THEN 1 ELSE 0 END) AS excluded_lines
FROM sales GROUP BY 1 ORDER BY revenue DESC""").df().to_string(index=False))
con.close()
