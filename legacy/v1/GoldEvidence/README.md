# GoldEvidence — Evidence-Based XAUUSD M5 System for MT5

**NO EVIDENCE = NO TRADE.** A rule engine finds candidates, a risk engine sizes and approves them, and
(on demo/live) Claude may only **reject** — never create or modify — a trade.

This is research software. It does not claim or guarantee profitability.

| Part | Path | Status |
|---|---|---|
| MQL5 Expert Advisor | `MQL5/Experts/GoldEvidence/GoldEvidenceEA.mq5` + `MQL5/Include/GoldEvidence/` | written, **needs first compile in MetaEditor** |
| Module 0 scripts | `MQL5/Scripts/GoldEvidence/GE_DataAudit.mq5`, `GE_ExportNews.mq5` | written, needs compile |
| Claude review service | `ai_service/` (Python, `requests` + `pydantic`, loopback only) | tested (17 tests) |
| Validation statistics | `analysis/backtest_stats.py` + `acceptance_criteria.json` | tested (6 tests) |
| Setup guide | `docs/INSTALL.md` | |
| Frozen protocol | `docs/VALIDATION_PROTOCOL.md` | v1 |

## Gate summary (every gate is mandatory; first failure = NO TRADE, logged)

| Gate | Check |
|---|---|
| G0 | data health: history for EMA200 warm-up, fresh tick, trading allowed |
| G1 | lockout, ≤ 5 trades/day, no open position, duplicate setup, post-loss cooldown |
| G2 | session, news, spread (abs, hourly median), ATR percentile 20–90 |
| G3 | H1 HH/HL (LH/LL), EMA 20>50>200, close vs EMA200, EMA50 slope, RSI vs 50 |
| G4 | M15 close vs EMA50, EMA20 vs 50, last swing intact, RSI vs 50 |
| G5 | M5 pullback 0.5–2.5 ATR, recent, M5 structure intact |
| G6 | pullback into ≥2-touch S/R zone or confirmed breakout-retest |
| G7 | RSI(M5) 50-cross or rising, not exhausted |
| G8 | engulfing / rejection / momentum trigger, range ≤ 2 ATR |
| G10 | structural SL 0.75–2.5 ATR, spread ≤ 10% SL, TP = 2R |
| G9 | no opposing zone before the 2R target |
| G11 | OrderCalcProfit-verified risk ≤ 0.5%, min-volume skip, daily-limit projection, margin |
| G12 | Claude CONFIRM (VETO mode only) |
| PRESEND | fresh price/spread re-check, geometry and risk recomputed |

## $100 sizing (Exness Standard Cent)

$100 = 10,000 USC → 0.5% = 50 USC. 0.01 cent lot of gold = 0.01 oz → 1 USC per $1 move.
A $8.50 stop: 50 / ((8.50 + 0.30) × 100) = 0.056 → **0.05 cent lots → 42.5 USC (0.43%)**.
On a $100 Standard account the same trade would risk 8.5% at the minimum lot, so the EA would skip every trade.

Start with `docs/INSTALL.md`.
