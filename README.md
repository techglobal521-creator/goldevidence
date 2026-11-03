# GoldEvidence

Evidence-based automated XAUUSD system for MetaTrader 5 (Exness). Rule: **no evidence = no trade**.

Current version: **v3 — Setup B only** (H1 Donchian-48 breakout, D1 SMA200 filter, 2xATR stop, opposite 24-bar channel exit, 120 h time stop) with an independent risk engine. Status: backtest/validation stage. **Not approved for live trading.**

## Layout
| Path | Contents |
|---|---|
| `mql5/Experts/GoldEvidence/EvidenceGold_v3.mq5` | Expert Advisor (single file, no external dependencies) |
| `tools/monte_carlo.py` | Drawdown / losing-streak simulation and kill-switch calibration |
| `docs/v3.1-spec.md` | Strategy and risk specification (source of truth) |
| `docs/implementation-status.md` | Decisions, results history, open items |
| `docs/INSTALL.md` | How to compile and backtest |
| `research/` | Python research code (to be added) |

## Validation gates (from the spec)
1. MT5 reproduces the Python Setup B results (trade count +/-10%, mean R +/-0.05R).
2. PF >= 1.20 and mean R > 0 after costs; mean R > 0 at 2x spread.
3. Positive in at least 2 of 3 sub-periods; Monte Carlo p95 drawdown <= 25%.
4. 90-day demo execution consistent with the model.

No result here is a promise of future profit.
