"""Core review logic, independent of the HTTP layer (so it can be unit-tested).

HTTP status contract with the EA:
  200 + decision CONFIRM  -> EA may trade (if rules and risk also passed)
  200 + decision REJECT   -> genuine review rejection (tracked as a virtual trade)
  401 / 400 / 413 / 503   -> error; EA treats as not confirmed (never trades)
"""
from __future__ import annotations

import hmac
import json
import threading
import time
from collections import OrderedDict
from typing import Any

from pydantic import ValidationError

from .audit_log import AuditLog
from .budget import Budget
from .claude_client import ReviewError, Reviewer
from .prompt import SYSTEM_PROMPT, VERDICT_TOOL, build_user_message
from .schemas import Candidate, VerdictOut
from .validation import finalize

MAX_BODY_BYTES = 256 * 1024


class ReviewService:
    def __init__(self, reviewer: Reviewer, ea_token: str, budget: Budget, audit: AuditLog, model: str) -> None:
        self.reviewer = reviewer
        self._token = ea_token.encode()
        self.budget = budget
        self.audit = audit
        self.model = model
        self._cache: OrderedDict[str, dict[str, Any]] = OrderedDict()
        self._lock = threading.Lock()

    def _authorised(self, token: str | None) -> bool:
        return token is not None and hmac.compare_digest(token.encode(), self._token)

    def handle(self, token: str | None, raw_body: bytes) -> tuple[int, dict[str, Any]]:
        if not self._authorised(token):
            return 401, {"error": "unauthorised"}
        if len(raw_body) > MAX_BODY_BYTES:
            return 413, {"error": "payload too large"}
        try:
            payload = json.loads(raw_body.decode("utf-8"))
            cand = Candidate.model_validate(payload)
        except (UnicodeDecodeError, ValueError, ValidationError) as exc:
            self.audit.write({"event": "bad_request", "error": str(exc)[:500]})
            return 400, {"error": "invalid candidate", "detail": str(exc)[:300]}

        cid = cand.candidate_id
        with self._lock:                       # idempotency: same candidate -> same answer, one API call
            if cid in self._cache:
                return 200, self._cache[cid]

        allowed, why = self.budget.try_reserve()
        if not allowed:
            self.audit.write({"event": "budget_block", "candidate_id": cid, "reason": why})
            return 503, {"error": why}

        t0 = time.monotonic()
        try:
            result = self.reviewer.review(SYSTEM_PROMPT, VERDICT_TOOL, build_user_message(payload))
        except ReviewError as exc:
            self.audit.write({"event": "review_error", "candidate_id": cid, "error": str(exc)[:500]})
            return 503, {"error": "review unavailable"}
        latency = int((time.monotonic() - t0) * 1000)
        cost = self.budget.record(result.usage)

        decision, summary, problems = finalize(payload, result.tool_input)
        out = VerdictOut(candidate_id=cid, decision=decision, summary=summary[:280],
                         model=result.model, latency_ms=latency).to_json_dict()
        self.audit.write({
            "event": "review", "candidate_id": cid, "decision": decision, "problems": problems,
            "model": result.model, "latency_ms": latency, "usage": result.usage, "cost_usd": round(cost, 6),
            "request": payload, "verdict_raw": result.tool_input,
        })
        with self._lock:
            self._cache[cid] = out
            while len(self._cache) > 500:
                self._cache.popitem(last=False)
        return 200, out
