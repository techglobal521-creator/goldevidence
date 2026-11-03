# D.2 data-audit tool (roadmap M0)

Implements checks D-1 to D-14 of the GoldEvidence specification rev 11 (section 8.1).
It flags and excludes data; it never repairs prices and never produces performance numbers.

**Status of thresholds:** rev 11 is awaiting owner confirmation. Values set by Claude are marked
`pending-owner` in `config.py` and in every report row. The daily-break hours are an
**UNVERIFIED default** and must be replaced with the broker's XAUUSD schedule before a real audit.

## Run

```
python -m tools.data_audit.run_audit --ticks ticks_2016.csv --calendar calendar.csv \
    --vendor-m5 m5_2016.csv --vendor-h1 h1_2016.csv --ref-h1 exness_h1_2026.csv \
    --ref-ticks exness_ticks_2026.csv --news news.csv --out audit_out/2016
```

Process one year per run to keep memory bounded. Outputs `report.json` and `report.md`.

## Tests

```
python -m pytest tools/data_audit/tests -q
```

16 tests on synthetic data cover every check, including the owner rules for D-5 (incomplete
window flagged, not deleted), D-6 (equal timestamps kept, only consecutive duplicates collapsed)
and D-12 (missing bars fail).

## Known limits

- D-3 and D-4 only flag; exclusion needs a human confirmation, as the spec says.
- D-10 searches whole-hour offsets only; DST changes must be checked per season.
- `calendar_template.csv` is empty: the holiday calendar must be built from the broker schedule and approved.
