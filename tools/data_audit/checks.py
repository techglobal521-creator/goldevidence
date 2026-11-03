"""D.2 data-audit checks D-1 .. D-14 (GoldEvidence spec rev 11, section 8.1).

Input conventions
- ticks: DataFrame with columns t (int64 ms, broker-server time), bid, ask; file order preserved.
- bars:  DataFrame with columns t (bar open, int64 ms), open, high, low, close (bid prices).
- Every check returns a dict with machine-readable results; nothing here edits source files.
- Checks flag or exclude; they never "repair" prices.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass

import numpy as np
import pandas as pd

from .config import AuditConfig

MS_MIN = 60_000
M5 = 5 * MS_MIN
MS_DAY = 86_400_000
SLOTS_PER_DAY = MS_DAY // M5  # 288


def day_of(t_ms) -> np.ndarray:
    return np.asarray(t_ms, dtype=np.int64) // MS_DAY


def to_date(day: int) -> pd.Timestamp:
    return pd.Timestamp(int(day) * MS_DAY, unit="ms").normalize()


def weekday_of_day(day) -> np.ndarray:
    return (np.asarray(day, dtype=np.int64) + 3) % 7   # Monday = 0


# --------------------------------------------------------------------------- calendar (D-9, D-14)
@dataclass
class Calendar:
    version: str
    sha256: str
    holidays: set
    half_days: set

    @classmethod
    def load(cls, path: str) -> "Calendar":
        raw = open(path, "rb").read()
        version = "unknown"
        holidays, half = set(), set()
        for line in raw.decode("utf-8").splitlines():
            s = line.strip()
            if not s:
                continue
            if s.startswith("#"):
                if "version:" in s:
                    version = s.split("version:", 1)[1].strip()
                continue
            if s.lower().startswith("date,"):
                continue
            date, kind = [x.strip() for x in s.split(",")[:2]]
            d = int(pd.Timestamp(date).value // 1_000_000 // MS_DAY)
            (holidays if kind == "holiday" else half).add(d)
        return cls(version, hashlib.sha256(raw).hexdigest(), holidays, half)

    def is_trading_day(self, day: int, weekdays=(0, 1, 2, 3, 4)) -> bool:
        return int(weekday_of_day(day)) in weekdays and day not in self.holidays


# --------------------------------------------------------------------------- D-6
def d6_clean(ticks: pd.DataFrame, cfg: AuditConfig) -> tuple[pd.DataFrame, dict]:
    """Collapse only consecutive rows identical in every field; keep equal timestamps in file
    order; days containing a decreasing timestamp are excluded (pending-owner)."""
    same_as_prev = (ticks.shift(1) == ticks).all(axis=1)
    same_as_prev.iloc[0] = False
    cleaned = ticks[~same_as_prev].reset_index(drop=True)
    dec = np.flatnonzero(np.diff(cleaned["t"].to_numpy()) < 0) + 1
    bad_days = sorted(set(day_of(cleaned["t"].to_numpy()[dec]).tolist()))
    return cleaned, {"check": "D-6", "duplicates_removed": int(same_as_prev.sum()),
                     "decreasing_timestamps": int(len(dec)), "excluded_days": bad_days,
                     "status": cfg.d6_decreasing_excludes_day.status}


# --------------------------------------------------------------------------- D-7
def d7_validity(ticks: pd.DataFrame, cfg: AuditConfig) -> tuple[pd.DataFrame, dict]:
    invalid = (ticks["ask"] <= ticks["bid"]).to_numpy()
    days = day_of(ticks["t"].to_numpy())
    df = pd.DataFrame({"day": days, "bad": invalid})
    frac = df.groupby("day")["bad"].mean()
    lim = cfg.d7_invalid_day_frac.value
    excl = sorted(int(d) for d, f in frac.items() if f > lim)
    return ticks[~invalid].reset_index(drop=True), {
        "check": "D-7", "invalid_removed": int(invalid.sum()), "excluded_days": excl,
        "threshold": lim, "status": cfg.d7_invalid_day_frac.status}


# --------------------------------------------------------------------------- D-5
def d5_outliers(ticks: pd.DataFrame, cfg: AuditConfig) -> tuple[pd.DataFrame, dict]:
    """Neighbours = 10 before + 10 after in file order, tick excluded. Fewer than 20 neighbours ->
    INSUFFICIENT_NEIGHBOURS flag, never deleted (owner rule). Single pass."""
    k = cfg.d5_half_window
    mid = ((ticks["bid"] + ticks["ask"]) / 2.0).to_numpy()
    n = len(mid)
    outlier = np.zeros(n, dtype=bool)
    insufficient = np.zeros(n, dtype=bool)
    insufficient[:k] = True
    insufficient[max(n - k, 0):] = True
    if n >= 2 * k + 1:
        win = np.lib.stride_tricks.sliding_window_view(mid, 2 * k + 1)
        neigh = np.delete(win, k, axis=1)
        med = np.median(neigh, axis=1)
        centre = mid[k:n - k]
        dev = np.abs(centre - med) / med
        outlier[k:n - k] = dev > cfg.d5_rel_dev.value
    removed_t = ticks["t"].to_numpy()[outlier]
    months = pd.Series(pd.to_datetime(ticks["t"], unit="ms").dt.to_period("M"))
    tot = months.value_counts()
    rem = months[outlier].value_counts()
    review = sorted(str(m) for m in rem.index if rem[m] / tot[m] > cfg.d5_month_review_frac.value)
    return ticks[~outlier].reset_index(drop=True), {
        "check": "D-5", "removed": int(outlier.sum()), "removed_times": removed_t.tolist()[:1000],
        "insufficient_neighbours": int(insufficient.sum()), "months_for_review": review,
        "status": f"incomplete-window rule: owner; 1% and 0.01%: {cfg.d5_rel_dev.status}"}


# --------------------------------------------------------------------------- bars
def bars_from_ticks(ticks: pd.DataFrame, tf_ms: int) -> pd.DataFrame:
    key = ticks["t"].to_numpy() // tf_ms
    g = ticks.assign(k=key).groupby("k", sort=True)
    out = pd.DataFrame({"t": g["k"].first().index.to_numpy() * tf_ms,
                        "open": g["bid"].first().to_numpy(), "high": g["bid"].max().to_numpy(),
                        "low": g["bid"].min().to_numpy(), "close": g["bid"].last().to_numpy(),
                        "n": g["bid"].size().to_numpy()})
    return out.reset_index(drop=True)


def atr_mt5(bars: pd.DataFrame, n: int = 14) -> np.ndarray:
    h, l, c = bars["high"].to_numpy(), bars["low"].to_numpy(), bars["close"].to_numpy()
    pc = np.r_[np.nan, c[:-1]]
    tr = np.maximum(h - l, np.maximum(np.abs(h - pc), np.abs(l - pc)))
    tr[0] = h[0] - l[0]
    return pd.Series(tr).rolling(n).mean().to_numpy()


def expected_slots(day: int, cfg: AuditConfig) -> np.ndarray:
    hrs = cfg.hours
    mins = np.arange(SLOTS_PER_DAY) * 5
    keep = ~((mins >= hrs.daily_break_start_min) & (mins < hrs.daily_break_end_min))
    return day * MS_DAY + mins[keep].astype(np.int64) * MS_MIN


# --------------------------------------------------------------------------- D-1, D-2
def d1_d2_coverage_gaps(m5: pd.DataFrame, cal: Calendar, cfg: AuditConfig, day_range) -> dict:
    have = set(m5["t"].tolist())
    rows, gap_days = [], []
    for day in range(day_range[0], day_range[1] + 1):
        if not cal.is_trading_day(day, cfg.hours.weekdays) or day in cal.half_days:
            continue
        slots = expected_slots(day, cfg)
        present = np.array([s in have for s in slots])
        rows.append((to_date(day).to_period("M"), len(slots), int(present.sum())))
        # longest run of missing slots
        run = best = 0
        for p in present:
            run = 0 if p else run + 1
            best = max(best, run)
        if best > cfg.d2_max_missing_bars.value:
            gap_days.append(day)
    df = pd.DataFrame(rows, columns=["month", "expected", "present"])
    by_m = df.groupby("month")[["expected", "present"]].sum()
    by_m["coverage"] = by_m["present"] / by_m["expected"]
    fail_months = [str(m) for m, r in by_m.iterrows() if r["coverage"] < cfg.d1_coverage_min.value]
    years = pd.Series([to_date(d).year for d in gap_days]).value_counts().to_dict()
    days_per_year = df.assign(y=df["month"].map(lambda p: p.year)).groupby("y").size().to_dict()
    fail_years = sorted(y for y, n in years.items() if n / days_per_year.get(y, 1) > cfg.d2_year_day_frac.value)
    return {"check": "D-1/D-2", "coverage_by_month": {str(m): round(float(r["coverage"]), 6) for m, r in by_m.iterrows()},
            "failed_months": fail_months, "gap_excluded_days": gap_days, "failed_years": fail_years,
            "trading_hours": cfg.hours.status,
            "status": f"D-1 {cfg.d1_coverage_min.status}; D-2 {cfg.d2_max_missing_bars.status}"}


# --------------------------------------------------------------------------- D-3
def d3_frozen(m5: pd.DataFrame, cfg: AuditConfig) -> dict:
    """Runs of >= 6 consecutive existing M5 bars, each range < 0.05 x ATR(14) at the bar before
    the run, all inside 07:00-20:00 Mon-Fri. Flags only; exclusion after confirmation."""
    atr = atr_mt5(m5)
    rng = (m5["high"] - m5["low"]).to_numpy()
    t = m5["t"].to_numpy()
    mins = (t % MS_DAY) // MS_MIN
    wd = weekday_of_day(day_of(t))
    in_hours = (mins >= cfg.d3_hours[0]) & (mins + 5 <= cfg.d3_hours[1]) & (wd < 5)
    flagged, i, n = [], 1, len(t)
    need = int(cfg.d3_run_bars.value)
    while i < n:
        ref = atr[i - 1]
        if not np.isfinite(ref) or not in_hours[i] or rng[i] >= cfg.d3_range_atr.value * ref:
            i += 1
            continue
        j = i
        while j < n and in_hours[j] and rng[j] < cfg.d3_range_atr.value * ref and day_of(t[j]) == day_of(t[i]):
            j += 1
        if j - i >= need:
            flagged.append({"start": int(t[i]), "bars": j - i, "day": int(day_of(t[i]))})
        i = max(j, i + 1)
    return {"check": "D-3", "flagged_runs": flagged,
            "flagged_days": sorted({f["day"] for f in flagged}), "status": cfg.d3_run_bars.status}


# --------------------------------------------------------------------------- D-4
def d4_spikes(bars: pd.DataFrame, cfg: AuditConfig, news_times_ms=None) -> dict:
    atr = atr_mt5(bars)
    rng = (bars["high"] - bars["low"]).to_numpy()
    prev_atr = np.r_[np.nan, atr[:-1]]
    idx = np.flatnonzero(np.isfinite(prev_atr) & (rng > cfg.d4_range_atr.value * prev_atr))
    news = np.sort(np.asarray(news_times_ms if news_times_ms is not None else [], dtype=np.int64))
    out = []
    for i in idx:
        t0 = int(bars["t"].iat[i])
        near = bool(len(news)) and bool(np.any(np.abs(news - t0) <= 30 * MS_MIN))
        out.append({"t": t0, "range_atr": float(rng[i] / prev_atr[i]),
                    "news_confirmed": near, "action": "keep" if near else "second-source check required"})
    return {"check": "D-4", "spikes": out, "status": cfg.d4_range_atr.status}


# --------------------------------------------------------------------------- D-8
def d8_spread(ticks: pd.DataFrame, cfg: AuditConfig) -> dict:
    sp = (ticks["ask"] - ticks["bid"]).to_numpy()
    s = pd.Series(sp).groupby(day_of(ticks["t"].to_numpy())).median()
    trail = s.shift(1).rolling(20, min_periods=10).median()
    flag = s > cfg.d8_spread_mult.value * trail
    return {"check": "D-8", "flagged_days": [int(d) for d in s.index[flag.fillna(False).to_numpy()]],
            "action": "flag and report only", "status": cfg.d8_spread_mult.status}


# --------------------------------------------------------------------------- D-9
def d9_density(ticks: pd.DataFrame, cal: Calendar, cfg: AuditConfig, excluded_days=()) -> dict:
    counts = pd.Series(1, index=day_of(ticks["t"].to_numpy())).groupby(level=0).sum()
    excluded = set(excluded_days)
    eligible = [d for d in counts.index if d not in cal.holidays and d not in cal.half_days]
    out_ex, skipped = [], []
    hist: list = []
    for d in eligible:
        prior = [counts[x] for x in hist[-cfg.d9_lookback_days:]]
        if len(prior) < cfg.d9_min_prior_days:
            skipped.append(int(d))
        elif counts[d] < cfg.d9_density_frac.value * float(np.median(prior)):
            out_ex.append(int(d))
        if d not in excluded and d not in out_ex:
            hist.append(d)
    return {"check": "D-9", "excluded_days": out_ex, "skipped_insufficient_history": skipped,
            "calendar_version": cal.version, "calendar_sha256": cal.sha256,
            "status": f"calendar rule: owner; 20%/20/10: {cfg.d9_density_frac.status}"}


# --------------------------------------------------------------------------- D-10, D-11
def d10_offset(src_h1: pd.DataFrame, ref_h1: pd.DataFrame, max_hours: int = 3) -> dict:
    """Find the whole-hour shift of src that best matches ref on the overlap; report alignment."""
    ref = ref_h1.set_index("t")["close"]
    best = None
    for h in range(-max_hours, max_hours + 1):
        s = src_h1.assign(t=src_h1["t"] + h * 3_600_000).set_index("t")["close"]
        common = s.index.intersection(ref.index)
        if len(common) == 0:
            continue
        med = float(np.median(np.abs(s[common] - ref[common]) / ref[common]))
        cand = {"offset_hours": h, "matched_bars": int(len(common)), "median_rel_diff": med}
        if best is None or med < best["median_rel_diff"]:
            best = cand
    return {"check": "D-10", "best": best,
            "note": "offset must be documented incl. DST; data unused until aligned",
            "status": "pending-owner"}


def d11_cross(src_h1: pd.DataFrame, ref_h1: pd.DataFrame, cfg: AuditConfig,
              src_ticks: pd.DataFrame | None = None, ref_ticks: pd.DataFrame | None = None) -> dict:
    a = src_h1.set_index("t")["close"]
    b = ref_h1.set_index("t")["close"]
    common = a.index.intersection(b.index)
    rel = (np.abs(a[common] - b[common]) / b[common]).to_numpy()
    med, p95 = (float(np.median(rel)), float(np.percentile(rel, 95))) if len(rel) else (np.nan, np.nan)
    res = {"check": "D-11", "bars": int(len(common)), "median_rel": med, "p95_rel": p95,
           "pass": bool(len(rel)) and med <= cfg.d11_median_rel.value and p95 <= cfg.d11_p95_rel.value,
           "label": "historical broker equivalence unverified (applies to 2015-2022)",
           "status": f"thresholds: {cfg.d11_median_rel.status}; spread-ratio rule: {cfg.d11_spread_ratio.status}"}
    if src_ticks is not None and ref_ticks is not None:
        def hourly(tk):
            hr = (tk["t"].to_numpy() % MS_DAY) // 3_600_000
            return pd.Series((tk["ask"] - tk["bid"]).to_numpy()).groupby(hr).median()
        ratio = (hourly(ref_ticks) / hourly(src_ticks)).dropna()
        res["spread_ratio_by_hour"] = {int(h): round(float(r), 4) for h, r in ratio.items()}
        res["hours_needing_scaled_spread"] = [int(h) for h, r in ratio.items() if r > cfg.d11_spread_ratio.value]
    return res


# --------------------------------------------------------------------------- D-12
def d12_resample(built: pd.DataFrame, vendor: pd.DataFrame, day_median_spread: pd.Series,
                 tf_label: str, cfg: AuditConfig) -> dict:
    """Missing bars in either source are failed comparisons (owner rule)."""
    m = built.merge(vendor, on="t", how="outer", suffixes=("_b", "_v"), indicator=True)
    tol = day_of(m["t"].to_numpy())
    tol = pd.Series(tol).map(day_median_spread).to_numpy()
    both = (m["_merge"] == "both").to_numpy()
    ok = np.zeros(len(m), dtype=bool)
    for f in ("open", "high", "low", "close"):
        diff = np.abs(m[f + "_b"].to_numpy() - m[f + "_v"].to_numpy())
        ok_f = diff <= tol
        ok = ok_f if f == "open" else ok & ok_f
    ok &= both & np.isfinite(tol)
    months = pd.to_datetime(m["t"], unit="ms").dt.to_period("M")
    frac = pd.Series(ok).groupby(months.to_numpy()).mean()
    fail = [str(k) for k, v in frac.items() if v < cfg.d12_pass_frac.value]
    return {"check": "D-12", "timeframe": tf_label, "pass_frac_by_month": {str(k): round(float(v), 6) for k, v in frac.items()},
            "failed_months": fail, "missing_in_one_source": int((~both).sum()),
            "status": f"missing-bar rule: owner; 99% and tolerance: {cfg.d12_pass_frac.status}"}


# --------------------------------------------------------------------------- D-13
NFP_KEYS = ("NONFARM", "NON-FARM")
FOMC_KEYS = ("FOMC", "FED INTEREST RATE", "FEDERAL FUNDS", "INTEREST RATE DECISION")


def d13_news(news: pd.DataFrame, start: str, end: str, cfg: AuditConfig) -> dict:
    """news columns: time (server time string), currency, importance, name."""
    t = pd.to_datetime(news["time"].str.replace(".", "-", regex=False))
    non_usd = int((news["currency"].str.upper() != "USD").sum())
    months_needed = pd.period_range(start, end, freq="M")
    have = set(t.dt.to_period("M"))
    missing = [str(m) for m in months_needed if m not in have]
    nm = news["name"].str.upper()
    yr = t.dt.year
    full_years = range(pd.Timestamp(start).year + (pd.Timestamp(start).month > 1),
                       pd.Timestamp(end).year + (pd.Timestamp(end).month == 12))
    per_year = {}
    for y in full_years:
        sel = yr == y
        per_year[int(y)] = {"nfp": int(nm[sel].apply(lambda s: any(k in s for k in NFP_KEYS)).sum()),
                            "fomc": int(nm[sel].apply(lambda s: any(k in s for k in FOMC_KEYS)).sum())}
    fail_years = [y for y, c in per_year.items()
                  if c["nfp"] < cfg.d13_min_nfp.value or c["fomc"] < cfg.d13_min_fomc.value]
    return {"check": "D-13", "non_usd_rows": non_usd, "missing_months": missing,
            "counts_by_year": per_year, "failed_years": fail_years, "status": cfg.d13_min_nfp.status}


# --------------------------------------------------------------------------- D-14
def d14_summary(excluded_days, excluded_months, cal: Calendar, cfg: AuditConfig, parts: dict) -> dict:
    out = {}
    ex_days = set(int(d) for d in excluded_days)
    for name, (a, b) in parts.items():
        d0 = int(pd.Timestamp(a).value // 1_000_000 // MS_DAY)
        d1 = int(pd.Timestamp(b).value // 1_000_000 // MS_DAY)
        trading = [d for d in range(d0, d1 + 1) if cal.is_trading_day(d, cfg.hours.weekdays)]
        month_days = {d for d in trading if str(to_date(d).to_period("M")) in set(excluded_months)}
        excl = (ex_days | month_days) & set(trading)
        frac = len(excl) / len(trading) if trading else float("nan")
        out[name] = {"denominator_trading_days": len(trading), "excluded_days": len(excl),
                     "excluded_frac": round(frac, 6), "pass": frac <= cfg.d14_max_excluded_frac.value}
    return {"check": "D-14", "parts": out, "calendar_version": cal.version,
            "calendar_sha256": cal.sha256, "status": cfg.d14_max_excluded_frac.status}
