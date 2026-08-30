"""Build a DuckDB warehouse from Optimo Excel exports.
Normalises Georgian headers -> clean English fields.
Usage: python scripts/build_warehouse.py
"""
import os, sys, glob
import pandas as pd, duckdb

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

RAW, OUT = "data/raw", "data/processed/quadro.duckdb"
os.makedirs("data/processed", exist_ok=True)

def norm_barcode(s):
    return (s.astype(str).str.strip()
             .str.replace(r"\.0$", "", regex=True)
             .str.replace(r"^\s*$", "", regex=True))

# ---------- retail sales lines ----------
r = pd.read_excel(f"{RAW}/sales_lines_retail.xlsx")
r.columns = ["receipt","txn","status","paymethod","product","barcode","staff","serial","qty",
             "line_value","date","vat","modifier","extras","cash","cashless","bog","bog_int",
             "tbc","liberty","procredit","keepz","manual","other"]
r["date"] = pd.to_datetime(r["date"], format="%m/%d/%Y %H:%M:%S %z", utc=True).dt.tz_convert("Asia/Tbilisi")
r["barcode"] = norm_barcode(r["barcode"])
r["is_return"] = r["status"].eq("დაბრუნებული")
# signed: returns subtract
r["net_qty"]   = r["qty"].where(~r["is_return"], -r["qty"])
r["net_value"] = r["line_value"].where(~r["is_return"], -r["line_value"])
r["channel"] = "retail"

# ---------- entity (B2B) sales lines ----------
e = pd.read_excel(f"{RAW}/sales_lines_entity.xlsx")
e.columns = ["receipt","product","barcode","company","taxid","txn","ctype","paymethod","paytype",
             "staff","status","qty","line_value","date","vat","modifier","extras"]
e["date"] = pd.to_datetime(e["date"], format="%m/%d/%Y %H:%M:%S %z", utc=True).dt.tz_convert("Asia/Tbilisi")
e["barcode"] = norm_barcode(e["barcode"])
e["is_cancelled"] = e["status"].eq("გაუქმებული")
e["net_qty"]   = e["qty"].where(~e["is_cancelled"], 0)
e["net_value"] = e["line_value"].where(~e["is_cancelled"], 0)
e["channel"] = "entity"

# ---------- stock on hand ----------
s = pd.read_excel(f"{RAW}/stock_on_hand.xlsx")
s.columns = ["barcode","product","supplier","category","qty_on_hand","unit_cost","total_cost"]
s["barcode"] = norm_barcode(s["barcode"])

# ---------- stock movement ----------
m = pd.read_excel(f"{RAW}/stock_movement.xlsx")
m.columns = ["barcode","product","supplier","type","open_qty","open_unit_cost","open_total_cost",
             "qty_in","qty_out","close_qty","close_unit_cost","close_total_cost"]
m["barcode"] = norm_barcode(m["barcode"])

con = duckdb.connect(OUT)
for name, df in [("sales_retail", r), ("sales_entity", e), ("stock", s), ("movement", m)]:
    con.execute(f"DROP TABLE IF EXISTS {name}")
    con.register("t", df); con.execute(f"CREATE TABLE {name} AS SELECT * FROM t"); con.unregister("t")
    print(f"  {name:<14} {len(df):>6,} rows")

# unified sales view (retail + entity), returns/cancellations already netted
con.execute("""
CREATE OR REPLACE VIEW sales AS
  SELECT channel, date, receipt, barcode, product, staff, paymethod,
         net_qty, net_value, NULL AS company
  FROM sales_retail
  UNION ALL
  SELECT channel, date, receipt, barcode, product, staff, paymethod,
         net_qty, net_value, company
  FROM sales_entity
""")
print("\nbarcode join coverage:")
print(con.execute("""
  SELECT s.channel,
         COUNT(*) AS lines,
         SUM(CASE WHEN st.barcode IS NULL THEN 1 ELSE 0 END) AS unmatched
  FROM sales s LEFT JOIN stock st USING (barcode) GROUP BY 1
""").df().to_string(index=False))
con.close()
print(f"\n-> {OUT}")

# ---------- daily statistics (Optimo's own aggregates) ----------
import pandas as _pd
_xl = _pd.ExcelFile(f"{RAW}/daily_statistics.xlsx")
_map = {"შემოსავალი":"revenue","ფასნამატი":"markup","ტრანზაქციები":"txns","საშუალო ქვითარი":"avg_receipt"}
_d = None
for _s in _xl.sheet_names:
    _t = _xl.parse(_s); _t.columns = ["date", _map[_s]]
    _t["date"] = _pd.to_datetime(_t["date"]).dt.date
    _d = _t if _d is None else _d.merge(_t, on="date", how="outer")
_con = duckdb.connect(OUT)
_con.execute("DROP TABLE IF EXISTS daily_stats")
_con.register("t", _d); _con.execute("CREATE TABLE daily_stats AS SELECT * FROM t"); _con.unregister("t")
print(f"  {'daily_stats':<14} {len(_d):>6,} rows")
_con.close()
