"""Inspect Optimo Excel exports: sheets, columns, row counts, sample values.
Usage: python scripts/inspect_exports.py [folder]
"""
import sys, glob, os
import pandas as pd

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

folder = sys.argv[1] if len(sys.argv) > 1 else "data/raw"
files = sorted(glob.glob(os.path.join(folder, "*.xls*")) + glob.glob(os.path.join(folder, "*.csv")))

if not files:
    print(f"No .xlsx/.xls/.csv files found in {folder!r}")
    sys.exit(0)

for f in files:
    size_kb = os.path.getsize(f) / 1024
    print("=" * 78)
    print(f"FILE: {os.path.basename(f)}   ({size_kb:,.1f} KB)")
    print("=" * 78)
    try:
        if f.lower().endswith(".csv"):
            sheets = {"<csv>": pd.read_csv(f)}
        else:
            xl = pd.ExcelFile(f)
            sheets = {s: xl.parse(s) for s in xl.sheet_names}
    except Exception as e:
        print(f"  !! could not read: {e}\n")
        continue

    for name, df in sheets.items():
        print(f"\n  SHEET {name!r}: {len(df):,} rows x {len(df.columns)} cols")
        print("  " + "-" * 74)
        for c in df.columns:
            col = df[c]
            nonnull = int(col.notna().sum())
            try:
                sample = [str(v)[:32] for v in col.dropna().unique()[:3]]
            except Exception:
                sample = []
            print(f"    {str(c)[:38]:<38} | {str(col.dtype):<12} | {nonnull:>6} nn | {sample}")
        print("\n  FIRST 3 ROWS:")
        with pd.option_context("display.max_columns", None, "display.width", 250):
            print(df.head(3).to_string()[:2000])
    print()
