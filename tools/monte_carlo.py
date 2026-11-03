"""GoldEvidence v3 - Monte Carlo drawdown and kill-switch calibration.

Input: either the EA journal (GoldEvidence_v3_journal.csv, rows with event=CLOSED)
or any CSV with a column named R (one R-multiple per closed trade, after costs).

Usage:
  python monte_carlo.py trades.csv --risk 0.5 --paths 10000 --trades 300 --block 5

Method: block bootstrap of the trade sequence (keeps some loss clustering),
compounding equity at a fixed % risk per trade. Reports drawdown and losing-streak
percentiles and proposes review / hard-stop levels for the EA inputs.
"""
import argparse
import re
import sys

import numpy as np
import pandas as pd


def load_r(path: str) -> np.ndarray:
    df = pd.read_csv(path)
    cols = {c.lower(): c for c in df.columns}
    if "r" in cols:
        r = pd.to_numeric(df[cols["r"]], errors="coerce").dropna().to_numpy()
    elif "event" in cols and "note" in cols:
        closed = df[df[cols["event"]] == "CLOSED"][cols["note"]].astype(str)
        r = np.array([float(m.group(1)) for s in closed if (m := re.search(r"R (-?\d+\.?\d*)", s))])
    else:
        sys.exit("CSV needs an 'R' column or EA journal format (event, note).")
    if len(r) < 30:
        sys.exit(f"Only {len(r)} trades - too few for a meaningful simulation (need 30+, ideally 100+).")
    return r


def simulate(r, risk_pct, n_paths, n_trades, block, seed=7):
    rng = np.random.default_rng(seed)
    n = len(r)
    risk = risk_pct / 100.0
    max_dd = np.empty(n_paths)
    final = np.empty(n_paths)
    streak = np.empty(n_paths, dtype=int)
    for p in range(n_paths):
        seq = []
        while len(seq) < n_trades:
            start = rng.integers(0, n)
            seq.extend(r[(start + np.arange(block)) % n])
        seq = np.array(seq[:n_trades])
        eq = np.cumprod(1.0 + seq * risk)
        peak = np.maximum.accumulate(np.concatenate(([1.0], eq)))[1:]
        max_dd[p] = np.max(1.0 - eq / peak) * 100
        final[p] = eq[-1]
        best = cur = 0
        for x in seq:
            cur = cur + 1 if x < 0 else 0
            best = max(best, cur)
        streak[p] = best
    return max_dd, final, streak


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--risk", type=float, default=0.5, help="risk per trade in %")
    ap.add_argument("--paths", type=int, default=10000)
    ap.add_argument("--trades", type=int, default=0, help="trades per path (default: sample size)")
    ap.add_argument("--block", type=int, default=5, help="bootstrap block length")
    a = ap.parse_args()

    r = load_r(a.csv)
    n_trades = a.trades or len(r)
    wins = r[r > 0]
    print(f"Sample: {len(r)} trades | mean {r.mean():+.3f}R | median {np.median(r):+.2f}R | "
          f"win {100*len(wins)/len(r):.1f}% | PF {wins.sum()/-r[r<0].sum():.2f}")
    se = r.std(ddof=1) / np.sqrt(len(r))
    print(f"Mean R 95% CI (normal approx): {r.mean()-1.96*se:+.3f} .. {r.mean()+1.96*se:+.3f}")
    top = np.sort(r)[::-1]
    print(f"Share of total R from top 5 trades: {100*top[:5].sum()/r.sum():.0f}%" if r.sum() > 0 else
          "Total R <= 0: no edge in this sample.")

    dd, final, streak = simulate(r, a.risk, a.paths, n_trades, a.block)
    q = lambda x, p: np.percentile(x, p)
    print(f"\n{a.paths} paths x {n_trades} trades at {a.risk}% risk (block {a.block})")
    print(f"Max drawdown %   p50 {q(dd,50):5.1f} | p75 {q(dd,75):5.1f} | p90 {q(dd,90):5.1f} | "
          f"p95 {q(dd,95):5.1f} | p99 {q(dd,99):5.1f}")
    print(f"Losing streak    p50 {q(streak,50):5.0f} | p95 {q(streak,95):5.0f} | p99 {q(streak,99):5.0f}")
    print(f"P(end below start) {100*np.mean(final<1):.1f}% | median end {100*(np.median(final)-1):+.1f}%")

    review = float(np.ceil(q(dd, 75)))
    hard = float(np.ceil(q(dd, 95)))
    print("\nSuggested EA inputs (normal variance should rarely trip these):")
    print(f"  InpReviewDDPct   = {review:.0f}   (p75 DD)")
    print(f"  InpHardStopDDPct = {hard:.0f}   (p95 DD)")
    if hard > 25:
        print("  WARNING: p95 DD exceeds the 25% acceptance limit at this risk - lower --risk.")


if __name__ == "__main__":
    main()
