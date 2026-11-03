"""D.2 data-audit thresholds — GoldEvidence spec rev 11, section 8.1.

Every value carries its approval status. "pending-owner" values were set by Claude (delegated)
and are NOT approved until the owner confirms them; the audit report prints this status next
to every result so nothing is presented as approved when it is not.
"""
from dataclasses import dataclass, field

SPEC_REVISION = "rev 11 (awaiting owner confirmation)"


@dataclass(frozen=True)
class Threshold:
    value: float
    status: str  # "owner" | "pending-owner"
    note: str = ""


@dataclass(frozen=True)
class TradingHours:
    """Expected trading slots for D-1. UNVERIFIED defaults: must be replaced with the broker's
    published XAUUSD schedule (GE_DataAudit audit_spec.txt) before a real audit."""
    weekdays: tuple = (0, 1, 2, 3, 4)          # Mon..Fri (server time)
    daily_break_start_min: int = 21 * 60       # break [start, end) in minutes of the server day
    daily_break_end_min: int = 22 * 60
    status: str = "UNVERIFIED default"


@dataclass(frozen=True)
class AuditConfig:
    d1_coverage_min: Threshold = Threshold(0.995, "pending-owner", "share of expected M5 bars per month")
    d2_max_missing_bars: Threshold = Threshold(2, "pending-owner", "consecutive missing M5 bars allowed")
    d2_year_day_frac: Threshold = Threshold(0.02, "pending-owner", "excluded-day share that fails a year")
    d3_run_bars: Threshold = Threshold(6, "pending-owner")
    d3_range_atr: Threshold = Threshold(0.05, "pending-owner")
    d3_hours: tuple = (7 * 60, 20 * 60)        # 07:00-20:00 server
    d4_range_atr: Threshold = Threshold(8.0, "pending-owner")
    d5_rel_dev: Threshold = Threshold(0.01, "pending-owner")
    d5_half_window: int = 10                   # owner-approved incomplete-window rule uses 20 neighbours
    d5_month_review_frac: Threshold = Threshold(0.0001, "pending-owner")
    d6_decreasing_excludes_day: Threshold = Threshold(1, "pending-owner", "rule owner-approved; day exclusion pending")
    d7_invalid_day_frac: Threshold = Threshold(0.001, "pending-owner")
    d8_spread_mult: Threshold = Threshold(3.0, "pending-owner", "flag only")
    d9_density_frac: Threshold = Threshold(0.20, "pending-owner")
    d9_lookback_days: int = 20
    d9_min_prior_days: int = 10
    d11_median_rel: Threshold = Threshold(0.000125, "owner")
    d11_p95_rel: Threshold = Threshold(0.0005, "owner")
    d11_spread_ratio: Threshold = Threshold(1.5, "pending-owner")
    d12_pass_frac: Threshold = Threshold(0.99, "pending-owner")
    d13_min_nfp: Threshold = Threshold(11, "pending-owner")
    d13_min_fomc: Threshold = Threshold(8, "pending-owner")
    d14_max_excluded_frac: Threshold = Threshold(0.03, "pending-owner")
    hours: TradingHours = field(default_factory=TradingHours)


DEFAULT = AuditConfig()

HISTORICAL_PARTS = {
    "part1": ("2015-01-01", "2019-12-31"),
    "part2": ("2020-01-01", "2022-10-31"),
}
