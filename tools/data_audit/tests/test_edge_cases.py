"""Edge-case tests for the D.2 audit checks (synthetic data only)."""
import numpy as np
import pandas as pd
import pytest

from tools.data_audit import checks as C
from tools.data_audit.config import DEFAULT as CFG
from tools.data_audit.run_audit import _time_ms

DAY = C.MS_DAY
MON = int(pd.Timestamp("2024-01-08").value // 1_000_000)
MON_DAY = MON // DAY


def ticks(start, n, step=1000, price=2000.0, spread=0.3):
    t = start + np.arange(n, dtype=np.int64) * step
    return pd.DataFrame({"t": t, "bid": np.full(n, price), "ask": np.full(n, price + spread)})


def empty_cal(tmp_path, body=""):
    p = tmp_path / "c.csv"
    p.write_text("# version: e\ndate,type,note\n" + body)
    return C.Calendar.load(str(p))


# ---------------------------------------------------------------- calendar
def test_calendar_rejects_unknown_type(tmp_path):
    with pytest.raises(ValueError):
        empty_cal(tmp_path, "2024-01-10,holday,typo\n")


def test_calendar_rejects_duplicate_date(tmp_path):
    with pytest.raises(ValueError):
        empty_cal(tmp_path, "2024-01-10,holiday,a\n2024-01-10,half_day,b\n")


def test_calendar_without_version_is_rejected(tmp_path):
    p = tmp_path / "c.csv"
    p.write_text("date,type,note\n2024-01-10,holiday,x\n")
    with pytest.raises(ValueError):
        C.Calendar.load(str(p))


# ---------------------------------------------------------------- D-6 / D-7
def test_d6_single_row_and_empty_input():
    one = ticks(MON, 1)
    out, rep = C.d6_clean(one, CFG)
    assert len(out) == 1 and rep["duplicates_removed"] == 0
    out, rep = C.d6_clean(one.iloc[0:0], CFG)
    assert len(out) == 0 and rep["excluded_days"] == []


def test_d6_identical_values_different_time_are_not_duplicates():
    df = pd.DataFrame({"t": [MON, MON + 1], "bid": [1.0, 1.0], "ask": [1.5, 1.5]})
    out, rep = C.d6_clean(df, CFG)
    assert rep["duplicates_removed"] == 0 and len(out) == 2


def test_d7_negative_spread_is_invalid():
    df = ticks(MON, 10)
    df.loc[3, "ask"] = df.loc[3, "bid"] - 0.5
    out, rep = C.d7_validity(df, CFG)
    assert rep["invalid_removed"] == 1 and len(out) == 9


# ---------------------------------------------------------------- D-5
def test_d5_short_file_only_flags():
    df = ticks(MON, 15)
    df.loc[7, ["bid", "ask"]] = [3000.0, 3000.3]
    out, rep = C.d5_outliers(df, CFG)
    assert rep["removed"] == 0 and rep["insufficient_neighbours"] == 15 and len(out) == 15


def test_d5_exactly_one_percent_is_not_removed():
    df = ticks(MON, 50, price=1000.0, spread=0.0)
    df.loc[25, ["bid", "ask"]] = [1010.0, 1010.0]          # exactly 1.0% -> not > 1%
    _, rep = C.d5_outliers(df, CFG)
    assert rep["removed"] == 0


def test_d5_month_review_flag():
    df = ticks(MON, 3000)
    df.loc[1000, ["bid", "ask"]] = [2100.0, 2100.3]       # 1 of 3000 = 0.033% > 0.01%
    _, rep = C.d5_outliers(df, CFG)
    assert rep["months_for_review"] == ["2024-01"]


# ---------------------------------------------------------------- D-1 / D-2
def _full_day_bars(day, drop=()):
    s = np.delete(C.expected_slots(day, CFG), list(drop))
    return pd.DataFrame({"t": s, "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0})


def test_d2_gap_at_start_of_day_counts(tmp_path):
    rep = C.d1_d2_coverage_gaps(_full_day_bars(MON_DAY, drop=[0, 1, 2]), empty_cal(tmp_path), CFG, (MON_DAY, MON_DAY))
    assert rep["gap_excluded_days"] == [MON_DAY]


def test_d2_break_slots_are_not_gaps(tmp_path):
    rep = C.d1_d2_coverage_gaps(_full_day_bars(MON_DAY), empty_cal(tmp_path), CFG, (MON_DAY, MON_DAY))
    assert rep["gap_excluded_days"] == [] and list(rep["coverage_by_month"].values()) == [1.0]


def test_d1_month_fails_below_threshold(tmp_path):
    jan31 = int(pd.Timestamp("2024-01-31").value // 1_000_000) // DAY   # Wednesday
    bars = _full_day_bars(jan31, drop=range(0, 2))                       # 2 missing of 276
    rep = C.d1_d2_coverage_gaps(bars, empty_cal(tmp_path), CFG, (jan31, jan31 + 1))
    assert rep["coverage_by_month"]["2024-01"] == pytest.approx(274 / 276)
    assert rep["coverage_by_month"]["2024-02"] == 0.0                  # Feb 1 has no bars
    assert set(rep["failed_months"]) == {"2024-01", "2024-02"}


def test_d2_year_fails_when_too_many_gap_days(tmp_path):
    days = [MON_DAY + d for d in range(0, 14) if C.weekday_of_day(MON_DAY + d) < 5]   # 10 weekdays
    frames = [_full_day_bars(d) for d in days[1:]]                                        # 1 of 10 empty
    rep = C.d1_d2_coverage_gaps(pd.concat(frames), empty_cal(tmp_path), CFG, (days[0], days[-1]))
    assert rep["gap_excluded_days"] == [days[0]] and rep["failed_years"] == [2024]       # 10% > 2%


# ---------------------------------------------------------------- D-3
def _bars(n, start, rng=1.0):
    t = start + np.arange(n, dtype=np.int64) * C.M5
    return pd.DataFrame({"t": t, "open": 2000.0, "high": 2000.0 + rng, "low": 2000.0, "close": 2000.0})


def test_d3_no_flag_before_atr_exists():
    b = _bars(30, MON + 7 * 3_600_000)
    b.loc[0:9, "high"] = b.loc[0:9, "low"] + 0.001                     # flat but ATR not formed
    assert C.d3_frozen(b, CFG)["flagged_runs"] == []


def test_d3_run_outside_hours_not_flagged():
    b = _bars(40, MON + 21 * 3_600_000)                                # 21:00 onward
    b.loc[20:30, "high"] = b.loc[20:30, "low"] + 0.001
    assert C.d3_frozen(b, CFG)["flagged_runs"] == []


def test_d3_weekend_not_flagged():
    sat = MON + 5 * DAY + 8 * 3_600_000
    b = _bars(40, sat)
    b.loc[20:30, "high"] = b.loc[20:30, "low"] + 0.001
    assert C.d3_frozen(b, CFG)["flagged_runs"] == []


# ---------------------------------------------------------------- D-4 / D-8 / D-9
def test_d4_news_outside_30_minutes_does_not_confirm():
    b = _bars(40, MON + 8 * 3_600_000)
    b.loc[30, "high"] = b.loc[30, "low"] + 9.0
    rep = C.d4_spikes(b, CFG, news_times_ms=[int(b["t"][30]) + 31 * C.MS_MIN])
    assert rep["spikes"][0]["news_confirmed"] is False


def test_d8_needs_ten_prior_days():
    frames = [ticks(MON + d * DAY, 20) for d in range(5)] + [ticks(MON + 5 * DAY, 20, spread=5.0)]
    assert C.d8_spread(pd.concat(frames, ignore_index=True), CFG)["flagged_days"] == []


def test_d9_excluded_days_not_used_as_reference(tmp_path):
    cal = empty_cal(tmp_path)
    days = [MON_DAY + d for d in range(0, 40) if C.weekday_of_day(MON_DAY + d) < 5]
    frames = []
    for i, d in enumerate(days):
        n = 1000 if i < 20 else (100000 if i == 20 else 1000)
        frames.append(ticks(d * DAY, n, step=500 if n > 1000 else 1000))
    # day 20 is huge but pre-excluded; it must not inflate the reference for day 21
    rep = C.d9_density(pd.concat(frames, ignore_index=True), cal, CFG, excluded_days=[days[20]])
    assert days[21] not in rep["excluded_days"]


# ---------------------------------------------------------------- D-11 / D-12 / D-13 / D-14
def test_d11_no_overlap_fails_cleanly():
    a = pd.DataFrame({"t": [MON], "close": [1.0]})
    b = pd.DataFrame({"t": [MON + 3_600_000], "close": [1.0]})
    r = C.d11_cross(a, b, CFG)
    assert r["bars"] == 0 and r["pass"] is False


def test_d12_missing_spread_for_day_fails_bar():
    t = MON + np.arange(10, dtype=np.int64) * C.M5
    b = pd.DataFrame({"t": t, "open": 1.0, "high": 1.0, "low": 1.0, "close": 1.0})
    rep = C.d12_resample(b, b.copy(), pd.Series(dtype=float), "M5", CFG)
    assert rep["failed_months"] == ["2024-01"]


def test_d13_missing_month_and_low_fomc_year():
    rows = [(f"2023.{m:02d}.06 13:30", "usd", "HIGH", "Non-Farm Employment Change") for m in range(1, 13) if m != 7]
    rows += [("2023.03.20 19:00", "USD", "HIGH", "Fed Interest Rate Decision")]
    rep = C.d13_news(pd.DataFrame(rows, columns=["time", "currency", "importance", "name"]), "2023-01-01", "2023-12-31", CFG)
    assert rep["missing_months"] == ["2023-07"] and rep["non_usd_rows"] == 0
    assert rep["counts_by_year"][2023] == {"nfp": 11, "fomc": 1} and rep["failed_years"] == [2023]


def test_d14_month_exclusion_and_day_counted_once(tmp_path):
    cal = empty_cal(tmp_path)
    parts = {"jan": ("2024-01-01", "2024-01-31")}                         # 23 weekdays
    rep = C.d14_summary([MON_DAY, MON_DAY], ["2024-01"], cal, CFG, parts)
    p = rep["parts"]["jan"]
    assert p["denominator_trading_days"] == 23 and p["excluded_days"] == 23


# ---------------------------------------------------------------- input parsing
def test_time_parsing_broker_string_and_ms():
    s = pd.Series(["2024.01.08 00:00:01.500"])
    assert int(_time_ms(s)[0]) == MON + 1500
    assert int(_time_ms(pd.Series([MON]))[0]) == MON
