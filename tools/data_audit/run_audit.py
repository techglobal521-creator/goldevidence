"""Run the D.2 data audit on one tick file and write report.json + report.md.

Example (one year per run keeps memory bounded):
  python -m tools.data_audit.run_audit --ticks ticks_2016.csv --calendar tools/data_audit/calendar.csv \
      --vendor-m5 dukascopy_m5_2016.csv --news news.csv --out audit_out/2016

Tick CSV columns: time (ms epoch, or 'YYYY.MM.DD HH:MM:SS.fff' broker-server time), bid, ask.
Bar CSV columns:  time, open, high, low, close (bid).
No performance numbers are produced. Every threshold prints its approval status.
"""
from __future__ import annotations

import argparse
import json
import os

import numpy as np
import pandas as pd

from . import checks as C
from .config import DEFAULT, HISTORICAL_PARTS, SPEC_REVISION


def _time_ms(col: pd.Series) -> np.ndarray:
    if pd.api.types.is_numeric_dtype(col):
        return col.to_numpy(dtype=np.int64)
    ts = pd.to_datetime(col.astype(str).str.replace(".", "-", n=2, regex=False))
    # resolution-independent (pandas 3 may store datetimes in us, not ns)
    return ((ts - pd.Timestamp(0)) // pd.Timedelta(milliseconds=1)).to_numpy(dtype=np.int64)


def load_ticks(path):
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    return pd.DataFrame({"t": _time_ms(df["time"]), "bid": df["bid"].astype(float), "ask": df["ask"].astype(float)})


def load_bars(path):
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    return pd.DataFrame({"t": _time_ms(df["time"]), **{k: df[k].astype(float) for k in ("open", "high", "low", "close")}})


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--ticks", required=True)
    ap.add_argument("--calendar", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--vendor-m5")
    ap.add_argument("--vendor-h1")
    ap.add_argument("--ref-h1", help="second source H1 (e.g. Exness) for D-10/D-11")
    ap.add_argument("--ref-ticks", help="second source ticks for the D-11 spread ratio")
    ap.add_argument("--news")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    cfg = DEFAULT
    cal = C.Calendar.load(a.calendar)

    raw = load_ticks(a.ticks)
    t6, r6 = C.d6_clean(raw, cfg)
    t7, r7 = C.d7_validity(t6, cfg)
    t5, r5 = C.d5_outliers(t7, cfg)
    m5 = C.bars_from_ticks(t5, C.M5)
    h1 = C.bars_from_ticks(t5, 3_600_000)
    days = C.day_of(t5["t"].to_numpy())
    rng = (int(days.min()), int(days.max()))
    r12 = C.d1_d2_coverage_gaps(m5, cal, cfg, rng)
    r3 = C.d3_frozen(m5, cfg)
    news = pd.read_csv(a.news) if a.news else None
    news_ms = None
    if news is not None:
        news_ms = _time_ms(news["time"])
    r4 = C.d4_spikes(m5, cfg, news_ms)
    r8 = C.d8_spread(t5, cfg)
    pre_excl = set(r6["excluded_days"]) | set(r7["excluded_days"]) | set(r12["gap_excluded_days"])
    r9 = C.d9_density(t5, cal, cfg, pre_excl)
    results = [r6, r7, r5, r12, r3, r4, r8, r9]
    spread_day = pd.Series((t5["ask"] - t5["bid"]).to_numpy()).groupby(days).median()
    if a.vendor_m5:
        results.append(C.d12_resample(m5[["t", "open", "high", "low", "close"]], load_bars(a.vendor_m5), spread_day, "M5", cfg))
    if a.vendor_h1:
        results.append(C.d12_resample(h1[["t", "open", "high", "low", "close"]], load_bars(a.vendor_h1), spread_day, "H1", cfg))
    if a.ref_h1:
        ref = load_bars(a.ref_h1)
        results.append(C.d10_offset(h1, ref))
        results.append(C.d11_cross(h1, ref, cfg, t5, load_ticks(a.ref_ticks) if a.ref_ticks else None))
    if news is not None:
        start, end = str(C.to_date(rng[0]).date()), str(C.to_date(rng[1]).date())
        results.append(C.d13_news(news, start, end, cfg))
    excluded = pre_excl | set(r9["excluded_days"])
    results.append(C.d14_summary(excluded, r12["failed_months"], cal, cfg, HISTORICAL_PARTS))

    report = {"spec": SPEC_REVISION, "ticks_file": a.ticks, "calendar_version": cal.version,
              "calendar_sha256": cal.sha256, "trading_hours": cfg.hours.status, "results": results}
    with open(os.path.join(a.out, "report.json"), "w") as fh:
        json.dump(report, fh, indent=1, default=str)
    with open(os.path.join(a.out, "report.md"), "w") as fh:
        fh.write(f"# Data audit report\n\nSpec: {SPEC_REVISION}\nCalendar: {cal.version} ({cal.sha256[:12]})\n"
                 f"Trading hours: {cfg.hours.status}\n\n| Check | Key result | Threshold status |\n|---|---|---|\n")
        for r in results:
            key = {k: v for k, v in r.items() if k not in ("check", "status") and not isinstance(v, (list, dict))}
            fh.write(f"| {r['check']} | {json.dumps(key, default=str)[:160]} | {r.get('status', '')} |\n")
    print(f"wrote {a.out}/report.json and report.md")


if __name__ == "__main__":
    main()
