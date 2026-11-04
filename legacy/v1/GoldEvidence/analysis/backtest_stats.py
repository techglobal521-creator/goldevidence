"""GoldEvidence validation statistics.

Reads the EA's trades.csv (Strategy Tester or demo) and produces a markdown report
judged against the frozen acceptance criteria. All headline numbers are in R
(P/L divided by planned risk), so they do not depend on account size.

Usage
-----
python -m analysis.backtest_stats trades.csv --out report.md
    [--criteria analysis/acceptance_criteria.json]
    [--baseline tester_optimization_random.csv]   # random-entry baseline runs (column "Custom" or "mean_r")
    [--virtual virtual.csv]                        # AI-vetoed virtual trades (demo, AI_VETO mode)
    [--label "OOS 2025-01..2026-06"]

Nothing here optimises parameters. It only measures.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

import numpy as np

DEFAULT_CRITERIA = Path(__file__).with_name("acceptance_criteria.json")


@dataclass
class Trade:
    position_id: str
    direction: str
    open_time: datetime
    close_time: datetime
    sl_dist: float
    planned_risk: float
    net_pnl: float
    r: float
    exit_reason: str
    spread: float
    ai_code: int
    balance_after: float


@dataclass
class Report:
    lines: list[str] = field(default_factory=list)
    checks: list[tuple[str, str, str, bool | None]] = field(default_factory=list)  # name, value, threshold, pass

    def h(self, text: str) -> None:
        self.lines += ["", text, ""]

    def p(self, text: str = "") -> None:
        self.lines.append(text)

    def check(self, name: str, value: str, threshold: str, ok: bool | None) -> None:
        self.checks.append((name, value, threshold, None if ok is None else bool(ok)))


def _dt(s: str) -> datetime:
    for fmt in ("%Y.%m.%d %H:%M", "%Y.%m.%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(s.strip(), fmt)
        except ValueError:
            continue
    raise ValueError(f"unrecognised time: {s!r}")


def load_trades(path: str | Path) -> list[Trade]:
    trades: list[Trade] = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for row in csv.DictReader(fh):
            if not row.get("r_multiple"):
                continue  # metadata lost (e.g. manual close of an unknown position) -> cannot be measured in R
            trades.append(Trade(
                position_id=row["position_id"], direction=row["dir"],
                open_time=_dt(row["open_time"]), close_time=_dt(row["close_time"]),
                sl_dist=float(row["sl_dist"] or 0), planned_risk=float(row["planned_risk"] or 0),
                net_pnl=float(row["net_pnl"]), r=float(row["r_multiple"]), exit_reason=row["exit_reason"],
                spread=float(row["spread_at_entry"] or 0), ai_code=int(float(row.get("ai_code") or -1)),
                balance_after=float(row["balance_after"] or 0),
            ))
    trades.sort(key=lambda t: t.close_time)
    return trades


# ----------------------------------------------------------------------------- core statistics
def profit_factor(pnl: np.ndarray) -> float:
    gp, gl = pnl[pnl > 0].sum(), -pnl[pnl < 0].sum()
    return math.inf if gl == 0 and gp > 0 else (gp / gl if gl > 0 else 0.0)


def longest_losing_streak(r: np.ndarray) -> int:
    best = cur = 0
    for x in r:
        cur = cur + 1 if x < 0 else 0
        best = max(best, cur)
    return best


def bootstrap_mean_ci(r: np.ndarray, n: int, alpha: float = 0.05, seed: int = 7) -> tuple[float, float]:
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(r), size=(n, len(r)))
    means = r[idx].mean(axis=1)
    return float(np.quantile(means, alpha / 2)), float(np.quantile(means, 1 - alpha / 2))


def drawdown_pct_from_equity(equity: np.ndarray) -> float:
    peak = np.maximum.accumulate(equity)
    return float(((peak - equity) / peak).max() * 100.0) if len(equity) else 0.0


def equity_from_r(r: np.ndarray, risk_frac: float, start: float = 1.0) -> np.ndarray:
    """Compounded equity when each trade risks `risk_frac` of current equity."""
    return start * np.cumprod(1.0 + r * risk_frac)


def monte_carlo_dd(r: np.ndarray, risk_frac: float, runs: int = 5000, seed: int = 11) -> np.ndarray:
    rng = np.random.default_rng(seed)
    out = np.empty(runs)
    for i in range(runs):
        eq = equity_from_r(rng.permutation(r), risk_frac)
        out[i] = drawdown_pct_from_equity(np.concatenate([[1.0], eq]))
    return out


def stress_r(trades: list[Trade], spread_mult: float, slip_price: float) -> np.ndarray:
    """Subtract extra costs, converted to R via each trade's SL distance.
    extra spread is paid once (entry); slippage on entry and on exit."""
    out = []
    for t in trades:
        if t.sl_dist <= 0:
            out.append(t.r)
            continue
        extra = (t.spread * spread_mult + 2 * slip_price) / t.sl_dist
        out.append(t.r - extra)
    return np.array(out)


def load_baseline(path: str | Path) -> np.ndarray:
    vals = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        rdr = csv.DictReader(fh)
        col = next((c for c in (rdr.fieldnames or []) if c.strip().lower() in ("custom", "mean_r", "result")), None)
        if col is None:
            raise ValueError("baseline CSV needs a 'Custom' or 'mean_r' column (MT5 optimisation export)")
        for row in rdr:
            try:
                vals.append(float(row[col]))
            except (TypeError, ValueError):
                continue
    return np.array(vals)


def load_virtual(path: str | Path) -> np.ndarray:
    with open(path, newline="", encoding="utf-8-sig") as fh:
        return np.array([float(row["r_multiple"]) for row in csv.DictReader(fh) if row.get("r_multiple")])


# ----------------------------------------------------------------------------- report
def fmt(x: float, d: int = 3) -> str:
    return "inf" if math.isinf(x) else f"{x:.{d}f}"


def analyse(trades: list[Trade], criteria: dict, label: str = "", baseline: np.ndarray | None = None,
            virtual: np.ndarray | None = None) -> Report:
    rep = Report()
    rep.p(f"# GoldEvidence validation report {('- ' + label) if label else ''}".rstrip())
    rep.p(f"Criteria version: `{criteria.get('version', '?')}`. All R values are P/L / planned risk.")
    n = len(trades)
    if n == 0:
        rep.p("\nNo measurable trades.")
        rep.check("Trade count", "0", f">= {criteria['min_trades_to_evaluate']}", False)
        return rep

    r = np.array([t.r for t in trades])
    pnl = np.array([t.net_pnl for t in trades])
    wins, losses = r[r > 0], r[r <= 0]
    exp = float(r.mean())
    sd = float(r.std(ddof=1)) if n > 1 else 0.0
    t_stat = exp / (sd / math.sqrt(n)) if sd > 0 else 0.0
    lo, hi = bootstrap_mean_ci(r, criteria["bootstrap_resamples"])
    pf = profit_factor(pnl)

    # realised drawdown from the balance column
    first_bal = trades[0].balance_after - trades[0].net_pnl
    bal = np.array([first_bal] + [t.balance_after for t in trades])
    dd_real = drawdown_pct_from_equity(bal)
    risk_fracs = []
    prev = first_bal
    for t in trades:
        if prev > 0 and t.planned_risk > 0:
            risk_fracs.append(t.planned_risk / prev)
        prev = t.balance_after
    rf = float(np.mean(risk_fracs)) if risk_fracs else 0.005
    mc = monte_carlo_dd(r, rf)
    mc95 = float(np.quantile(mc, 0.95))

    # monthly concentration
    by_month: dict[str, float] = defaultdict(float)
    for t in trades:
        by_month[t.close_time.strftime("%Y-%m")] += t.r
    total_pos = sum(v for v in by_month.values() if v > 0)
    max_share = max(by_month.values()) / total_pos if total_pos > 0 else 1.0
    stressed = stress_r(trades, criteria["stress_extra_spread_mult"], criteria["stress_extra_slippage_price"])

    rep.h("## Summary")
    rep.p("| Metric | Value |")
    rep.p("|---|---|")
    rows = [
        ("Trades", str(n)),
        ("Period", f"{trades[0].open_time:%Y-%m-%d} .. {trades[-1].close_time:%Y-%m-%d}"),
        ("Win rate", f"{len(wins) / n * 100:.1f}%"),
        ("Average win (R)", fmt(float(wins.mean())) if len(wins) else "-"),
        ("Average loss (R)", fmt(float(losses.mean())) if len(losses) else "-"),
        ("Expectancy (mean R)", fmt(exp)),
        ("Bootstrap 95% CI of mean R", f"[{fmt(lo)}, {fmt(hi)}]"),
        ("t-statistic of mean R", fmt(t_stat, 2)),
        ("Profit factor (net)", fmt(pf, 2)),
        ("Realised max drawdown", f"{dd_real:.2f}%"),
        ("Monte Carlo drawdown p50 / p95", f"{np.quantile(mc, 0.5):.2f}% / {mc95:.2f}%"),
        ("Average risk per trade", f"{rf * 100:.3f}%"),
        ("Longest losing streak", str(longest_losing_streak(r))),
        ("Largest single-month share of positive R", f"{max_share * 100:.1f}%"),
        ("Stressed expectancy (spread x1.5, +slippage)", fmt(float(stressed.mean()))),
        ("Total R / net P/L", f"{r.sum():.2f} R / {pnl.sum():.2f}"),
    ]
    for k, v in rows:
        rep.p(f"| {k} | {v} |")

    # breakdowns
    rep.h("## Breakdown")
    rep.p("| Group | Trades | Win % | Mean R | Total R |")
    rep.p("|---|---|---|---|---|")

    def grp(name: str, sel: list[Trade]) -> None:
        if not sel:
            return
        rr = np.array([t.r for t in sel])
        rep.p(f"| {name} | {len(sel)} | {(rr > 0).mean() * 100:.1f} | {rr.mean():.3f} | {rr.sum():.2f} |")

    grp("BUY", [t for t in trades if t.direction == "BUY"])
    grp("SELL", [t for t in trades if t.direction == "SELL"])
    for y in sorted({t.close_time.year for t in trades}):
        grp(str(y), [t for t in trades if t.close_time.year == y])
    for h0, h1 in ((0, 10), (10, 14), (14, 18), (18, 24)):
        grp(f"open {h0:02d}-{h1:02d}h (server)", [t for t in trades if h0 <= t.open_time.hour < h1])
    for reason in sorted({t.exit_reason for t in trades}):
        grp(f"exit {reason}", [t for t in trades if t.exit_reason == reason])

    # acceptance checks
    c = criteria
    enough = n >= c["min_trades_to_evaluate"]
    rep.check("Trade count", str(n), f">= {c['min_trades_to_evaluate']} (pref. {c['preferred_trades']})", enough)
    rep.check("Expectancy", fmt(exp), f">= {c['min_expectancy_r']}", exp >= c["min_expectancy_r"])
    rep.check("Bootstrap lower bound", fmt(lo), f"> {c['bootstrap_lower_bound_gt']}", lo > c["bootstrap_lower_bound_gt"])
    rep.check("Profit factor", fmt(pf, 2), f">= {c['min_profit_factor']}", pf >= c["min_profit_factor"])
    rep.check("Realised drawdown", f"{dd_real:.2f}%", f"<= {c['max_realised_drawdown_pct']}%", dd_real <= c["max_realised_drawdown_pct"])
    rep.check("Monte Carlo p95 drawdown", f"{mc95:.2f}%", f"<= {c['max_mc_p95_drawdown_pct']}%", mc95 <= c["max_mc_p95_drawdown_pct"])
    rep.check("Single-month concentration", f"{max_share * 100:.1f}%", f"<= {c['max_single_month_share'] * 100:.0f}%",
              max_share <= c["max_single_month_share"])
    rep.check("Stressed expectancy", fmt(float(stressed.mean())), f"> {c['stress_min_expectancy_r']}",
              float(stressed.mean()) > c["stress_min_expectancy_r"])

    if baseline is not None and len(baseline):
        q = float(np.percentile(baseline, c["baseline_percentile"]))
        rep.h("## Random-entry baseline")
        rep.p(f"{len(baseline)} baseline runs. Mean of baseline mean-R: {baseline.mean():.3f}; "
              f"{c['baseline_percentile']}th percentile: {q:.3f}. Strategy mean R: {exp:.3f}.")
        rep.check("Beats random baseline", fmt(exp), f"> baseline p{c['baseline_percentile']} ({q:.3f})", exp > q)
    else:
        rep.check("Beats random baseline", "not run", "required before go/no-go", None)

    if virtual is not None and len(virtual):
        conf = np.array([t.r for t in trades if t.ai_code == 1])
        rep.h("## AI value test (forward data only)")
        rep.p(f"AI-confirmed trades: {len(conf)} (mean R {conf.mean():.3f})" if len(conf) else "No AI-confirmed trades.")
        rep.p(f"AI-rejected (virtual) trades: {len(virtual)} (mean R {virtual.mean():.3f})")
        if len(conf) >= 20 and len(virtual) >= 20:
            rng = np.random.default_rng(3)
            diffs = [rng.choice(conf, len(conf)).mean() - rng.choice(virtual, len(virtual)).mean() for _ in range(5000)]
            dlo, dhi = np.quantile(diffs, [0.05, 0.95])
            rep.p(f"Confirmed minus rejected, 90% CI: [{dlo:.3f}, {dhi:.3f}]. "
                  f"The AI filter shows value only if the lower bound is > 0.")
        else:
            rep.p("Fewer than 20 trades in a group: not enough evidence to judge the AI filter yet.")
    shadow_rej = np.array([t.r for t in trades if t.ai_code == 2])
    if len(shadow_rej):
        conf = np.array([t.r for t in trades if t.ai_code == 1])
        rep.h("## AI shadow-mode comparison")
        rep.p(f"Trades the AI would have confirmed: {len(conf)}, mean R {conf.mean() if len(conf) else float('nan'):.3f}. "
              f"Trades the AI would have rejected: {len(shadow_rej)}, mean R {shadow_rej.mean():.3f}.")

    rep.h("## Acceptance checks")
    rep.p("| Check | Value | Threshold | Result |")
    rep.p("|---|---|---|---|")
    for name, val, thr, ok in rep.checks:
        res = "n/a" if ok is None else ("PASS" if ok else "FAIL")
        rep.p(f"| {name} | {val} | {thr} | {res} |")
    hard = [ok for _, _, _, ok in rep.checks]
    if not enough:
        verdict = "INSUFFICIENT EVIDENCE - not enough trades to judge. Do not trade live."
    elif all(ok is True for ok in hard):
        verdict = "ALL CRITERIA PASSED - proceed to the next validation stage (not a profitability guarantee)."
    elif any(ok is False for ok in hard):
        verdict = "FAILED - at least one criterion failed. NO-GO."
    else:
        verdict = "INCOMPLETE - some required checks have not been run."
    rep.h("## Verdict")
    rep.p(f"**{verdict}**")
    rep.p("")
    rep.p("Past results, including out-of-sample results, do not guarantee future performance.")
    return rep


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trades")
    ap.add_argument("--out", default="report.md")
    ap.add_argument("--criteria", default=str(DEFAULT_CRITERIA))
    ap.add_argument("--baseline")
    ap.add_argument("--virtual")
    ap.add_argument("--label", default="")
    a = ap.parse_args(argv)
    criteria = json.loads(Path(a.criteria).read_text(encoding="utf-8"))
    trades = load_trades(a.trades)
    rep = analyse(trades, criteria, a.label,
                  load_baseline(a.baseline) if a.baseline else None,
                  load_virtual(a.virtual) if a.virtual else None)
    Path(a.out).write_text("\n".join(rep.lines) + "\n", encoding="utf-8")
    print(f"wrote {a.out}  ({len(trades)} trades)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
