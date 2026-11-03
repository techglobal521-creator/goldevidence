# GoldEvidence — Implementation status (updated 2026-11-03)

## Decisions
- v1 (2026-11-01): 0.5% risk, 2% daily, veto-only Claude, trend pullback only.
- v2 (2026-11-02, owner decision): 1.5% risk per trade, 5% daily loss limit, five setups (S1 trend pullback relaxed, S2 breakout-retest, S3 London/NY opening-range breakout, S4 Monday gap fill, S5 post-news surprise), Claude may propose trades. Min 1:2 RR, 5 trades/day, one position, SL+TP always.
- v3.1 (2026-11-03, owner: "fix the gaps and move on"): Setup B only, unchanged rules (H1/D1, no M5/EMA/RSI); 0.5% risk; 1% daily / 3% weekly entry locks; DD review + hard stop calibrated by Monte Carlo (start 12% / 20%); rolling-50 mean R < -0.10 stop; safety TP 8R, real exit = channel/time; Claude has no trade authority. Full spec: docs/v3.1-spec.md.
- Live account if ever validated: Exness Standard Cent, $100. Testing: Exness Standard demo $10,000.

## Environment
- Exness MT5 demo, $10,000, 1:100. XAUUSDm contract 100, min/step 0.01, stops level 0. Server time GMT+0. (Account login kept out of the repo.)
- News CSV v2: 3,686 events, 2,854 with impact. Dukascopy ticks Nov 2022 - Dec 2025 in custom symbol XAUUSD_DK (171M ticks). Exness real ticks only from 2026-01.
- Dukascopy bid candles (D1 2004-, H1 2012-, M5 2022-11 to 2026-10) in MetaQuotes\Terminal\Common\Files\ticks and Downloads.

## Bugs fixed (v2)
- MarketData.mqh BarsCalculated gate -> 0 trades in tester (fixed).
- Force-close applied at any time after 20:45 -> S4 Monday-gap trades closed instantly at the weekly open (fixed in Filters.mqh, v2.1).

## Results (v2 defaults)
- Development 2022-11..2024-06: 50 trades, win 34%, mean -0.165R, PF 0.74, DD 18.1%.
- OOS-1 2024-07..2025-12: 94 trades, win 37%, mean -0.053R (95% CI -0.31..+0.21), PF 0.90, max DD 24.4%. FAILS acceptance.
- Combined 144 trades: mean -0.09R. v2 is NO-GO. No live trading.

## Research sprint 2026-11-03 (Python, pre-registered, holdout run once)
- A D1 Donchian55: holdout +1.10R/45 trades, CI incl. 0, one +39R trade dominates -> fail.
- B H1 Donchian48 + D1 SMA200 filter, 2xATR stop, opposite-24 exit / 5-day max: dev +0.10R (403), val 2020-22 +0.12R (161), holdout 2023-26 +0.225R (222), PF 1.34, stress +0.195R; CI -0.02..+0.50. Full 2012-26: +0.14R, 786 trades; DD 49% at 1.5% risk, 18% at 0.5%. Profit from fat-tail winners.
- C hour-of-day drift and D M5 RSI2 pullback: negative in dev, rejected.
- Holdout 2023-26 is spent; new filters only by walk-forward on 2012-2022.

## Lot feasibility (2026-11-03, XAUUSD about 3,940, H1 ATR about $12-18)
- 2xATR stop about $25-36. Exness Standard 0.01 lot (1 oz) = about 30% of $100 -> impossible. Standard Cent 0.01 cent lot (about 0.01 oz) = about 0.3% -> feasible at 0.5% budget, not at 0.25%. Confirm XAUUSDc contract size in MT5.

## v3 build (2026-11-03)
- mql5/Experts/GoldEvidence/EvidenceGold_v3.mq5: pure Setup B, risk engine, journal CSV, R persistence, startup feasibility print. NOT yet compiled.
- tools/monte_carlo.py: tested on synthetic data.
- Reproduction points to confirm vs Python B: time stop 120 calendar hours vs 120 bars; re-entry on the exit bar (EA: no); ATR period 14.

## Missing from this repo
- v1 code (Desktop\GoldEvidence_v1: EA modules, ai_service, analysis, docs).
- v2 code (S1-S5, bug fixes) — location to confirm (MT5 data folder).
- Python research code and Setup B trade list (needed for reproduction).

## Next steps
1. Compile v3; MT5 tester on XAUUSD_DK; compare with Python B trade list (count +/-10%, mean R +/-0.05R).
2. Cost stress (1.5x/2x spread, swap) -> monte_carlo.py on tester trades -> set DD inputs.
3. 2026 Exness real-tick tester run, then 90-day demo.
