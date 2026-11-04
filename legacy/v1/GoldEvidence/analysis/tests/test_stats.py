"""Tests for the validation statistics using synthetic trade journals."""
from __future__ import annotations

import csv
import json
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np

from analysis.backtest_stats import (DEFAULT_CRITERIA, analyse, bootstrap_mean_ci, drawdown_pct_from_equity,
                                     load_trades, longest_losing_streak, main, profit_factor)

HEADER = ("position_id,symbol,dir,open_time,close_time,entry,exit,sl_dist,lots,planned_risk,worst_risk,net_pnl,"
          "r_multiple,exit_reason,spread_at_entry,mae_r,mfe_r,ai_code,balance_after").split(",")


def write_journal(path: Path, rs: list[float], start=10000.0, risk_pct=0.0042, spread=0.2, sld=6.0, ai=0):
    bal = start
    t0 = datetime(2025, 1, 2, 9, 0)
    with open(path, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(HEADER)
        for i, r in enumerate(rs):
            risk = bal * risk_pct
            pnl = r * risk
            bal += pnl
            ot = t0 + timedelta(days=i * 1.4)
            w.writerow([i + 1, "XAUUSDc", "BUY" if i % 3 else "SELL", ot.strftime("%Y.%m.%d %H:%M"),
                        (ot + timedelta(hours=2)).strftime("%Y.%m.%d %H:%M"), 4000, 4000 + r * sld, sld, 0.07,
                        f"{risk:.2f}", f"{risk * 1.05:.2f}", f"{pnl:.2f}", f"{r:.3f}", "TP" if r > 0 else "SL",
                        spread, "", "", ai, f"{bal:.2f}"])


def crit():
    return json.loads(Path(DEFAULT_CRITERIA).read_text())


def test_primitives():
    assert profit_factor(np.array([2.0, -1.0, -1.0])) == 1.0
    assert longest_losing_streak(np.array([1, -1, -1, -1, 2, -1])) == 3
    assert abs(drawdown_pct_from_equity(np.array([100.0, 110.0, 99.0, 120.0])) - 10.0) < 1e-9
    lo, hi = bootstrap_mean_ci(np.array([1.0] * 50), 500)
    assert lo == hi == 1.0


def test_no_edge_fails(tmp_path):
    rng = np.random.default_rng(1)
    rs = list(np.where(rng.random(300) < 1 / 3, 2.0, -1.0) - 0.05)   # breakeven minus costs
    p = tmp_path / "t.csv"
    write_journal(p, rs)
    rep = analyse(load_trades(p), crit())
    text = "\n".join(rep.lines)
    assert "NO-GO" in text or "INCOMPLETE" in text
    exp_check = [c for c in rep.checks if c[0] == "Expectancy"][0]
    assert exp_check[3] is False


def test_small_sample_is_insufficient(tmp_path):
    p = tmp_path / "t.csv"
    write_journal(p, [2.0, -1.0, 2.0, 2.0, -1.0] * 8)    # 40 trades, looks great
    text = "\n".join(analyse(load_trades(p), crit()).lines)
    assert "INSUFFICIENT EVIDENCE" in text


def test_strong_edge_with_baseline_passes(tmp_path):
    rng = np.random.default_rng(5)
    rs = list(np.where(rng.random(400) < 0.48, 2.0, -1.0))           # strong synthetic edge (~+0.44R)
    p = tmp_path / "t.csv"
    write_journal(p, rs)
    base = tmp_path / "b.csv"
    with open(base, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["Pass", "Custom"])
        for i, v in enumerate(rng.normal(-0.05, 0.08, 100)):
            w.writerow([i, v])
    out = tmp_path / "r.md"
    assert main([str(p), "--out", str(out), "--baseline", str(base)]) == 0
    text = out.read_text()
    assert "ALL CRITERIA PASSED" in text, text


def test_stress_reduces_expectancy(tmp_path):
    p = tmp_path / "t.csv"
    write_journal(p, [2.0, -1.0, -1.0, 2.0] * 30, spread=0.4, sld=2.0)
    rep = analyse(load_trades(p), crit())
    summary = dict(line.strip("| ").split(" | ")[:2] for line in rep.lines if line.startswith("| ") and " | " in line
                   and not line.startswith("| Metric") and not line.startswith("|---"))
    assert float(summary["Stressed expectancy (spread x1.5, +slippage)"]) < float(summary["Expectancy (mean R)"])


def test_ai_value_section(tmp_path):
    p = tmp_path / "t.csv"
    write_journal(p, [2.0, -1.0, -1.0] * 40, ai=1)
    v = tmp_path / "v.csv"
    with open(v, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["candidate_id", "dir", "open_time", "close_time", "entry", "sl", "tp", "result", "r_multiple"])
        for i in range(30):
            w.writerow([f"GE-{i}", "BUY", "", "", 1, 1, 1, "SL", -1.0])
    out = tmp_path / "r.md"
    main([str(p), "--out", str(out), "--virtual", str(v)])
    assert "AI value test" in out.read_text()
