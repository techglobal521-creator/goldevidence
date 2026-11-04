"""Hard caps on Claude usage: calls per UTC day and USD per UTC month.

State is persisted to <log_dir>/usage_state.json so restarts do not reset caps.
Cost is estimated from the usage block of each response with configurable prices.
"""
from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone


class Budget:
    def __init__(self, path: str, max_calls_per_day: int, max_usd_per_month: float,
                 price_in_per_mtok: float, price_out_per_mtok: float) -> None:
        self.path = path
        self.max_calls_per_day = max_calls_per_day
        self.max_usd_per_month = max_usd_per_month
        self.pin = price_in_per_mtok
        self.pout = price_out_per_mtok
        self._lock = threading.Lock()
        self._state = {"day": "", "calls": 0, "month": "", "usd": 0.0}
        if os.path.exists(path):
            try:
                with open(path, encoding="utf-8") as fh:
                    self._state.update(json.load(fh))
            except (OSError, ValueError):
                pass

    @staticmethod
    def _now() -> datetime:
        return datetime.now(timezone.utc)

    def _roll(self) -> None:
        now = self._now()
        day, month = now.strftime("%Y-%m-%d"), now.strftime("%Y-%m")
        if self._state["day"] != day:
            self._state["day"], self._state["calls"] = day, 0
        if self._state["month"] != month:
            self._state["month"], self._state["usd"] = month, 0.0

    def _save(self) -> None:
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self._state, fh)
        os.replace(tmp, self.path)

    def try_reserve(self) -> tuple[bool, str]:
        """Reserve one call slot. Returns (allowed, reason)."""
        with self._lock:
            self._roll()
            if self._state["calls"] >= self.max_calls_per_day:
                return False, f"daily call cap reached ({self.max_calls_per_day})"
            if self._state["usd"] >= self.max_usd_per_month:
                return False, f"monthly budget reached (${self.max_usd_per_month:.2f})"
            self._state["calls"] += 1
            self._save()
            return True, ""

    def cost_of(self, usage: dict[str, int]) -> float:
        tin = usage.get("input_tokens", 0) + usage.get("cache_creation_input_tokens", 0) * 1.25 \
            + usage.get("cache_read_input_tokens", 0) * 0.1
        tout = usage.get("output_tokens", 0)
        return tin / 1e6 * self.pin + tout / 1e6 * self.pout

    def record(self, usage: dict[str, int]) -> float:
        cost = self.cost_of(usage)
        with self._lock:
            self._roll()
            self._state["usd"] = round(self._state["usd"] + cost, 6)
            self._save()
        return cost

    def snapshot(self) -> dict:
        with self._lock:
            self._roll()
            return dict(self._state)
