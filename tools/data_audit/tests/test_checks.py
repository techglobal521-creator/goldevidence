"""Unit tests for the D.2 audit checks on synthetic data only (no market data, no performance)."""
import numpy as np
import pandas as pd
import pytest

from tools.data_audit import checks as C
from tools.data_audit.config import DEFAULT as CFG

DAY = C.MS_DAY
MON = int(pd.Timestamp("2024-01-08").value // 1_000_000)   # a Monday 00:00
MON_DAY = MON // DAY


def ticks_every(start_ms, n, step_ms=1000, price=2000.0, spread=0.3):
    t = start_ms + np.arange(n, dtype=np.int64) * step_ms
    bid = np.full(n, price)
    return pd.DataFrame({"t": t, "bid": bid, "ask": bid + spread})


@pytest.fixture
def cal(tmp_path):
    p = tmp_path / "cal.csv"
    p.write_text("# version: test-1\ndate,type,note\n2024-01-10,holiday,test\n2024-01-11,half_day,test\n")
    return C.Calendar.load(str(p))


def test_calendar_version_and_hash(cal):
    assert cal.version == "test-1" and len(cal.sha256) == 64
    assert MON_DAY + 2 in cal.holidays and MON_DAY + 3 in cal.half_days
    assert cal.is_trading_day(MON_DAY) and not cal.is_trading_day(MON_DAY + 2)
    assert not cal.is_trading_day(MON_DAY + 5)          # Saturday


def test_d6_equal_timestamps_kept_consecutive_duplicates_collapsed():
    df = pd.DataFrame({"t": [MON, MON, MON, MON + 5], "bid": [1.0, 1.0, 1.1, 1.2], "ask": [1.5, 1.5, 1.6, 1.7]})
    out, rep = C.d6_clean(df, CFG)
    assert rep["duplicates_removed"] == 1
    assert list(out["t"]) == [MON, MON, MON + 5]          # equal timestamps stay, file order kept
    assert rep["excluded_days"] == []


def test_d6_non_consecutive_identical_rows_kept_and_decreasing_excludes_day():
    df = pd.DataFrame({"t": [MON, MON + 10, MON, MON + 20], "bid": [1.0, 1.1, 1.0, 1.2], "ask": [1.5, 1.6, 1.5, 1.7]})
    out, rep = C.d6_clean(df, CFG)
    assert rep["duplicates_removed"] == 0 and len(out) == 4
    assert rep["decreasing_timestamps"] == 1 and rep["excluded_days"] == [MON_DAY]


def test_d7_invalid_quotes_removed_and_day_excluded_above_limit():
    df = ticks_every(MON, 1000)
    df.loc[5, "ask"] = df.loc[5, "bid"]                   # 1 invalid in 1000 = 0.1% -> not above limit
    out, rep = C.d7_validity(df, CFG)
    assert rep["invalid_removed"] == 1 and rep["excluded_days"] == [] and len(out) == 999
    df.loc[6, "ask"] = df.loc[6, "bid"] - 1               # 2 in 1000 = 0.2% -> excluded
    _, rep = C.d7_validity(df, CFG)
    assert rep["excluded_days"] == [MON_DAY]


def test_d5_outlier_removed_but_edge_ticks_only_flagged():
    df = ticks_every(MON, 100)
    df.loc[50, ["bid", "ask"]] = [2100.0, 2100.3]        # +5% spike in the middle
    df.loc[0, ["bid", "ask"]] = [2100.0, 2100.3]         # spike at the edge (<20 neighbours)
    out, rep = C.d5_outliers(df, CFG)
    assert rep["removed"] == 1 and int(df["t"][50]) in rep["removed_times"]
    assert int(df["t"][0]) not in rep["removed_times"]    # incomplete window: flagged, not deleted
    assert rep["insufficient_neighbours"] == 20
    assert len(out) == 99


def test_d1_d2_coverage_and_gap(cal):
    # full Monday of M5 bars except break (21:00-22:00 UNVERIFIED default) and a 3-bar hole
    slots = C.expected_slots(MON_DAY, CFG)
    slots = np.delete(slots, [100, 101, 102])
    m5 = pd.DataFrame({"t": slots, "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0})
    rep = C.d1_d2_coverage_gaps(m5, cal, CFG, (MON_DAY, MON_DAY))
    cov = list(rep["coverage_by_month"].values())[0]
    assert cov == pytest.approx(1 - 3 / 276)
    assert rep["gap_excluded_days"] == [MON_DAY]           # 3 missing > 2 allowed
    m5b = pd.DataFrame({"t": np.delete(C.expected_slots(MON_DAY, CFG), [100, 101]),
                        "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0})
    assert C.d1_d2_coverage_gaps(m5b, cal, CFG, (MON_DAY, MON_DAY))["gap_excluded_days"] == []


def test_d1_skips_holidays_and_half_days(cal):
    m5 = pd.DataFrame({"t": C.expected_slots(MON_DAY, CFG), "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0})
    rep = C.d1_d2_coverage_gaps(m5, cal, CFG, (MON_DAY, MON_DAY + 3))
    # Tue missing entirely (gap day); Wed holiday and Thu half day are not expected at all
    assert rep["gap_excluded_days"] == [MON_DAY + 1]


def _m5_bars(n, start=MON + 7 * 3_600_000, rng=1.0):
    t = start + np.arange(n, dtype=np.int64) * C.M5
    base = 2000 + np.arange(n) * 0.0
    return pd.DataFrame({"t": t, "open": base, "high": base + rng, "low": base, "close": base})


def test_d3_frozen_run_flagged_only_inside_hours():
    bars = _m5_bars(40)
    bars.loc[20:25, "high"] = bars.loc[20:25, "low"] + 0.01     # 6 flat bars, ATR ~1.0 -> 0.01 < 0.05
    rep = C.d3_frozen(bars, CFG)
    assert len(rep["flagged_runs"]) == 1 and rep["flagged_runs"][0]["bars"] == 6
    bars.loc[25, "high"] = bars.loc[25, "low"] + 1.0            # run of 5 -> not flagged
    assert C.d3_frozen(bars, CFG)["flagged_runs"] == []


def test_d4_spike_needs_confirmation_unless_news():
    bars = _m5_bars(40)
    bars.loc[30, "high"] = bars.loc[30, "low"] + 9.0            # 9x ATR
    rep = C.d4_spikes(bars, CFG)
    assert len(rep["spikes"]) == 1 and rep["spikes"][0]["action"] == "second-source check required"
    rep = C.d4_spikes(bars, CFG, news_times_ms=[int(bars["t"][30]) + 10 * C.MS_MIN])
    assert rep["spikes"][0]["news_confirmed"] and rep["spikes"][0]["action"] == "keep"


def test_d8_wide_spread_day_flagged_not_removed():
    frames = [ticks_every(MON + d * DAY, 50, spread=0.3) for d in range(15)]
    frames.append(ticks_every(MON + 15 * DAY, 50, spread=1.2))  # 4x
    rep = C.d8_spread(pd.concat(frames, ignore_index=True), CFG)
    assert rep["flagged_days"] == [MON_DAY + 15] and rep["action"] == "flag and report only"


def test_d9_thin_day_excluded_and_short_history_skipped(cal):
    frames = []
    days = [MON_DAY + d for d in range(0, 30) if C.weekday_of_day(MON_DAY + d) < 5]
    for i, d in enumerate(days):
        n = 1000 if i != 15 else 100                              # day 15 at 10% density
        frames.append(ticks_every(d * DAY, n))
    rep = C.d9_density(pd.concat(frames, ignore_index=True), cal, CFG)
    assert days[15] not in cal.holidays and days[15] not in cal.half_days
    assert rep["excluded_days"] == [days[15]]
    eligible = [d for d in days if d not in cal.holidays and d not in cal.half_days]
    assert rep["skipped_insufficient_history"] == eligible[:10]   # fewer than 10 prior eligible days
    assert rep["calendar_version"] == "test-1"


def test_d10_finds_whole_hour_offset():
    t = MON + np.arange(100, dtype=np.int64) * 3_600_000
    px = 2000 + np.sin(np.arange(100)) * 10
    ref = pd.DataFrame({"t": t, "close": px})
    src = pd.DataFrame({"t": t - 2 * 3_600_000, "close": px})    # src is 2 h behind
    assert C.d10_offset(src, ref)["best"]["offset_hours"] == 2


def test_d11_relative_thresholds_and_label():
    t = MON + np.arange(50, dtype=np.int64) * 3_600_000
    ref = pd.DataFrame({"t": t, "close": np.full(50, 4000.0)})
    ok = pd.DataFrame({"t": t, "close": np.full(50, 4000.2)})    # 0.005%
    bad = pd.DataFrame({"t": t, "close": np.full(50, 4001.0)})   # 0.025%
    assert C.d11_cross(ok, ref, CFG)["pass"] is True
    r = C.d11_cross(bad, ref, CFG)
    assert r["pass"] is False and "unverified" in r["label"]


def test_d12_missing_bar_is_failure():
    t = MON + np.arange(200, dtype=np.int64) * C.M5
    b = pd.DataFrame({"t": t, "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0})
    v = b.drop(index=[5, 6, 7]).reset_index(drop=True)          # 3 bars missing in vendor
    sp = pd.Series({MON_DAY: 0.3})
    rep = C.d12_resample(b, v, sp, "M5", CFG)
    assert rep["missing_in_one_source"] == 3
    assert rep["failed_months"] == ["2024-01"]                   # 197/200 = 98.5% < 99%


def test_d13_news_counts_and_coverage():
    rows = []
    for m in range(1, 13):
        rows.append((f"2023.{m:02d}.06 13:30", "USD", "HIGH", "Nonfarm Payrolls"))
        if m in (1, 3, 5, 6, 7, 9, 11, 12):
            rows.append((f"2023.{m:02d}.20 19:00", "USD", "HIGH", "FOMC Statement"))
    rows.append(("2023.04.01 08:00", "EUR", "HIGH", "ECB"))
    news = pd.DataFrame(rows, columns=["time", "currency", "importance", "name"])
    rep = C.d13_news(news, "2023-01-01", "2023-12-31", CFG)
    assert rep["counts_by_year"][2023] == {"nfp": 12, "fomc": 8}
    assert rep["failed_years"] == [] and rep["missing_months"] == [] and rep["non_usd_rows"] == 1


def test_d14_denominator_excludes_weekends_and_holidays(cal):
    parts = {"wk": ("2024-01-08", "2024-01-14")}                  # Mon..Sun, Wed holiday
    rep = C.d14_summary([MON_DAY], [], cal, CFG, parts)
    p = rep["parts"]["wk"]
    assert p["denominator_trading_days"] == 4                     # Mon Tue Thu Fri (half day counts)
    assert p["excluded_frac"] == pytest.approx(0.25) and p["pass"] is False
    assert rep["calendar_sha256"] == cal.sha256
