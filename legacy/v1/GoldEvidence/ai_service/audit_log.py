"""Append-only JSONL audit log of every review (request, verdict, usage, outcome).

The log never contains the Anthropic API key or the EA token: neither is part of
the payloads written here.
"""
from __future__ import annotations

import json
import os
import threading
from datetime import datetime, timezone
from typing import Any


class AuditLog:
    def __init__(self, log_dir: str) -> None:
        os.makedirs(log_dir, exist_ok=True)
        self.path = os.path.join(log_dir, "ai_calls.jsonl")
        self._lock = threading.Lock()

    def write(self, record: dict[str, Any]) -> None:
        record = {"ts_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"), **record}
        line = json.dumps(record, ensure_ascii=False, separators=(",", ":"))
        with self._lock, open(self.path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
