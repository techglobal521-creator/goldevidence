# GoldEvidence — Installation & Setup (Windows, MT5, Exness)

Budget assumption: **$100 live capital on an Exness Standard Cent account** (balance shown as 10,000 USC).
Testing happens first on the Strategy Tester and an Exness **Standard demo with $10,000** (100× scaled
equivalent, because Standard Cent has no demo).

> Nothing here is financial advice. The system has **not** been shown to be profitable. Follow the
> validation protocol (`docs/VALIDATION_PROTOCOL.md`) before any live use.

---

## 1. Accounts you need

| Purpose | Account | Balance | Cost |
|---|---|---|---|
| Backtests (Strategy Tester) | any Exness MT5 login (demo is fine) | tester deposit 10,000 (USD) | free |
| Forward demo | Exness **Standard** demo, MT5 | **$10,000** | free |
| Live (only after validation + your authorisation) | Exness **Standard Cent**, MT5, leverage 1:100–1:200 | $100 = 10,000 USC | $100 |
| Claude API | console.anthropic.com, separate key with spend limit | — | ~$1–3 / month with the default caps |

Why $10,000 demo: on Standard, 0.01 lot = 1 oz. On Cent, 0.01 cent lot = 0.01 oz. A $10,000 Standard
account therefore behaves exactly like a $100 Cent account (same risk %, same lot granularity relative to equity).

**Before anything else**, open MT5 → Market Watch → right-click the gold symbol → *Specification* on each
account and write down: contract size, volume min/step, digits, stops level. The EA prints these on start-up too.

## 2. Copy the MT5 files

In MT5: *File → Open Data Folder*. Copy from this project:

```
MQL5/Experts/GoldEvidence/GoldEvidenceEA.mq5   -> <DataFolder>/MQL5/Experts/GoldEvidence/
MQL5/Include/GoldEvidence/*.mqh                -> <DataFolder>/MQL5/Include/GoldEvidence/
MQL5/Scripts/GoldEvidence/*.mq5                -> <DataFolder>/MQL5/Scripts/GoldEvidence/
```

Open MetaEditor (F4), open each `.mq5` and press **Compile** (F7).

> This code was written without access to the MQL5 compiler. Expect possibly a few compile errors on the
> first build; copy the exact error lines from MetaEditor's *Errors* tab and send them back for fixing.
> Do not "fix" errors by deleting checks.

## 3. Module 0 — data audit and news file (run once, on the demo terminal)

1. Open an **XAUUSD M5** chart (on the Cent account later, `XAUUSDc`).
2. Run script **GE_ExportNews** (Navigator → Scripts → GoldEvidence). It writes
   `Common\Files\GoldEvidence_news_USD.csv`. The EA refuses to start in the tester without it.
   Check one known NFP time in the file against the chart to confirm the time base.
3. Run script **GE_DataAudit** with the date range you plan to test. Output in
   `MQL5\Files\GoldEvidence\audit_*`. Look at:
   - `audit_spec.txt` → `server_minus_gmt_hours` (session hours in the EA are **server time**)
   - `audit_ticks_daily.csv` → days flagged `NO_TICKS_WEEKDAY` / `LOW_TICKS` (data gaps)
   - `audit_spread_hour.csv` → spread per hour; confirm the session window avoids wide-spread hours
   - `audit_sizing.csv` → run it once with *InpEquity = 10000* on the Standard demo: `feasible` must be YES

## 4. Strategy Tester (Module 6)

- Expert: `GoldEvidence\GoldEvidenceEA`, symbol XAUUSD, any chart period (logic uses M5/M15/H1).
- Modelling: **Every tick based on real ticks**. Deposit **10000 USD**. Leverage 1:200.
- Delays: enable random delay.
- Start the test ~2 months *before* the period you want to measure (indicator / spread-history warm-up;
  the EA logs gate G0 until it has enough history).
- Inputs: leave defaults. `InpAIMode` is ignored in the tester (forced OFF).
- Results: `trades.csv`, `decisions.csv` are written in the **tester agent** folder:
  `<DataFolder>\Tester\Agent-127.0.0.1-3000\MQL5\Files\GoldEvidence\` (agent name may differ).
- Random baseline: set `InpStrategy = GE_STRAT_RANDOM`, optimise `InpRandomSeed` from 1 to 100
  (slow complete algorithm), export the optimisation results to CSV. The *Custom* column is the mean R per run.

Analyse:

```
pip install -r ai_service/requirements.txt numpy
python -m analysis.backtest_stats path\to\trades.csv --out oos_report.md --baseline random_runs.csv --label "OOS"
```

## 5. Claude review service (Module 7–8, demo only)

```
cd GoldEvidence
python -m venv .venv
.venv\Scripts\activate
pip install -r ai_service\requirements.txt

rem secrets: set for this window only (or use keyring, see config.py)
set ANTHROPIC_API_KEY=sk-ant-...your key...
set GE_EA_TOKEN=<random 32+ characters, e.g. from: python -c "import secrets;print(secrets.token_hex(24))">
set GE_MAX_USD_PER_MONTH=3
python -m ai_service
```

Check: open `http://127.0.0.1:8787/health` in a browser → `"status": "ok"`.

In MT5: *Tools → Options → Expert Advisors* → tick **Allow WebRequest for listed URL** and add
`http://127.0.0.1:8787`. Attach the EA to an XAUUSD chart on the **demo** account with:

- `InpAIMode = GE_AI_SHADOW` for the first 4 weeks, then `GE_AI_VETO`
- `InpAIToken` = the same value as `GE_EA_TOKEN`
- Enable *Algo Trading*.

Never put the Anthropic key in the EA. The EA only knows the local token.
The service writes `ge_logs/ai_calls.jsonl` (every request and verdict) and `ge_logs/usage_state.json`.

Run the service tests any time: `python -m pytest ai_service/tests analysis/tests -q`

## 6. Going live (only after the protocol says GO and you authorise it)

1. Open an Exness **Standard Cent** MT5 account, leverage 1:100–1:200, deposit $100.
2. Attach the EA to the `XAUUSDc` chart. Check the start-up line in the *Experts* tab: contract size,
   min volume and account currency (USC) must match your Specification notes.
3. Same inputs as the validated demo. Risk stays 0.5%. Keep the PC/VPS and the service running.
4. Review `trades.csv` weekly. Any rule violation, missing SL/TP, or behaviour that differs from demo → stop.
