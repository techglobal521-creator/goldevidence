# Install and backtest (EA v3)

1. MT5 -> File -> Open Data Folder -> `MQL5\Experts`. Copy `mql5/Experts/GoldEvidence/EvidenceGold_v3.mq5` into `MQL5\Experts\GoldEvidence\`.
2. Press F4 (MetaEditor), open the file, press F7. Expect `0 errors`.
3. Strategy Tester (Ctrl+R):
   - Expert: EvidenceGold_v3 | Symbol: XAUUSD_DK | Period: H1
   - Dates: 2022.11.01 - 2025.12.31 | Modelling: Every tick based on real ticks
   - Deposit 10000 USD | Leverage 1:100 | Inputs: defaults
4. After the run, the journal is at `<Terminal>\Common\Files\GoldEvidence_v3_journal.csv`.
5. Monte Carlo:
   ```
   pip install numpy pandas
   python tools/monte_carlo.py GoldEvidence_v3_journal.csv --risk 0.5
   ```
6. Check the `Feasibility:` line in the tester Journal tab: it shows what the minimum lot risks at the current ATR.

Backtest only. Do not attach the EA to a demo or live chart until the validation gates in the README pass.
