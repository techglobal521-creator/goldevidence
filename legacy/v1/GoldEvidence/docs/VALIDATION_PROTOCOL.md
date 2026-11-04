# GoldEvidence — Validation Protocol v1 (frozen 2026-11-01)

This protocol is written **before** any backtest is run. Changing it after seeing results invalidates them.

## 1. Hypothesis

On XAUUSD, entries in the direction of an aligned H1/M15 trend, taken on a closed M5 trigger candle after an
ATR-normalised pullback into a validated support/resistance or breakout-retest zone, with a structural stop and a
fixed 2R target, have positive expectancy **after spread and slippage**.

The null hypothesis (no edge) is the default belief until the evidence below rejects it.

## 2. Frozen parameters (v1)

All EA inputs at their defaults in `GoldEvidenceEA.mq5` as of v1.00. Key values:

| Parameter | Value | Parameter | Value |
|---|---|---|---|
| Risk per trade | 0.5% equity | Daily loss limit | 2% |
| Max trades/day | 5 | Reward:risk | 2.0 |
| H1 EMA50 slope | ≥ 0.10 ATR / 5 bars | Swing significance | 1.0 ATR |
| Fractal half-width | 2 | Pullback depth | 0.5–2.5 ATR(M5) |
| Pullback age | ≤ 3 bars | RSI(M5) cap | 70 / 30 |
| Trigger range | ≤ 2.0 ATR(M5) | SL buffer | max(0.2 ATR, 2×spread) |
| SL distance | 0.75–2.5 ATR(M5) | Spread | ≤ 10% of SL, ≤ 2× hourly median, ≤ 0.60 |
| ATR percentile | 20th–90th | Zone tolerance | 0.25 ATR(H1), ≥ 2 touches |
| Session (server) | 07:00–20:00, Fri until 18:00 | Force close | 20:45, Fri 20:00 |
| News block | ±30 min high-impact USD; ±60 min FOMC/NFP/CPI | Slippage buffer | 0.30 |

Session hours are provisional until Module 0 confirms the Exness server time zone. Adjusting them **once**,
based only on the spread audit (not on strategy results), is allowed and must be recorded below.

## 3. Data split

| Segment | Period | Rule |
|---|---|---|
| Development | earliest real ticks → 2024-12-31 | Debugging only. Look at decisions.csv to confirm gates behave as designed. Do not tune for profit. |
| Out-of-sample | 2025-01-01 → 2026-06-30 | Run **once** with frozen v1. Judge with `analysis/acceptance_criteria.json`. |
| Forward demo | from go-ahead, ≥ 3 months and ≥ 50 trades | 4 weeks AI_SHADOW, then AI_VETO. |

Report BUY and SELL separately: 2025–2026 contained a strong gold uptrend.

## 4. Tests to run (in order)

1. **Development run** — sanity only. Check: no trade without SL/TP, risk ≤ 0.5% on every trade,
   no more than 5 entries per day, lockout after −2%, rejection funnel plausible (most bars fail at G2/G3).
2. **Out-of-sample run** — the one that counts.
3. **Stress** — automatic in the report (spread ×1.5, +0.10 slippage each side).
4. **Random-entry baseline** — `InpStrategy = GE_STRAT_RANDOM`, seeds 1–100, same OOS period.
   `InpRandomProb` set so the baseline trade count is similar to the strategy's.
5. **Ablation** — one run per switch `InpUseG4..G9 = false`. A gate that does not improve mean R or drawdown is
   a candidate for removal in v2 (v2 then needs fresh out-of-sample data).
6. **Robustness** — ±20% on pullback depth limits, SL buffer, H1 slope, zone tolerance (one at a time).
   Expectancy must stay > 0. This is a check, not a search for the best value.

## 5. Acceptance (from `analysis/acceptance_criteria.json`)

Out-of-sample, net of costs: ≥ 100 trades (200 preferred); mean R ≥ +0.10 with bootstrap 95% lower bound > 0;
profit factor ≥ 1.25; realised max DD ≤ 8%, Monte Carlo p95 DD ≤ 12%; no month > 25% of positive R;
stressed expectancy > 0; mean R above the 95th percentile of the random baseline.

Fewer than 100 OOS trades = **INSUFFICIENT EVIDENCE**, which is a no-go, not a pass.

## 6. Forward demo pass

≥ 50 trades; mean R inside the OOS bootstrap 90% interval; realised spread/slippage within modelled values;
zero risk-rule violations; zero positions without SL/TP; lockouts work.
AI filter is kept only if AI-confirmed trades beat AI-rejected (virtual) trades with a 90% CI lower bound > 0;
otherwise run with `GE_AI_OFF` (rules only).

## 7. Live gate

All of the above passed + written review of logs + **explicit authorisation by the account owner**.
Live starts on Standard Cent, $100, risk 0.5%, unchanged parameters.

## 8. Change log (append only)

| Date | Change | Reason | Data seen before change? |
|---|---|---|---|
| 2026-11-01 | v1 frozen | initial | none |
