"""Tests for the review service. Claude is replaced by fakes; no network is used
except a loopback HTTP round-trip in the last test."""
from __future__ import annotations

import json
import threading
from http.server import ThreadingHTTPServer

import pytest
import requests

from ai_service.claude_client import ClaudeClient, ReviewError, ReviewResult
from ai_service.config import Settings
from ai_service.server import build_service, make_handler
from ai_service.validation import path_exists

TOKEN = "t" * 24


def candidate(cid="GE-1793512277-BUY", direction="BUY"):
    entry, sl, tp = (4000.0, 3994.0, 4012.0) if direction == "BUY" else (4000.0, 4006.0, 3988.0)
    return {
        "schema": "candidate.v1", "candidate_id": cid, "server_time": "2026.11.02 10:35", "symbol": "XAUUSDc",
        "direction": direction,
        "proposal": {"entry": entry, "sl": sl, "tp": tp, "rr": 2.0, "risk_pct": 0.42},
        "market": {"spread": 0.2, "atr_m5": 5.1, "atr_m15": 8.7, "atr_h1": 17.2, "atr_m5_pctile": 0.55},
        "h1": {"structure": "BULLISH", "ema20": 3991.2, "ema50": 3975.4, "ema200": 3902.8, "rsi": 58.4,
               "swings": [{"type": "LOW", "price": 3950.0, "time": "2026.11.01 22:00"}]},
        "m15": {"structure": "BULLISH", "rsi": 54.1, "ema50": 3990.0},
        "m5": {"rsi": 52.7, "rsi_prev": 48.9},
        "setup": {"location": "SUPPORT", "zone_low": 3993.5, "zone_high": 3996.0, "zone_touches": 3, "trigger": "ENGULFING"},
        "levels": [{"low": 3993.5, "high": 3996.0, "touches": 3}],
        "bars": {"m5": [["2026.11.02 10:30", 3998.0, 4001.0, 3995.0, 4000.5]], "m15": [], "h1": []},
    }


GOOD_CONFIRM = {
    "decision": "CONFIRM",
    "evidence": [
        {"claim": "H1 bullish with EMA stack", "fields": ["h1.structure", "h1.ema20", "h1.ema50"]},
        {"claim": "Pullback into 3-touch support", "fields": ["setup.zone_low", "levels.0.touches"]},
        {"claim": "RSI recovered above 50", "fields": ["m5.rsi", "m5.rsi_prev"]},
    ],
    "contradictions": [{"issue": "M5 RSI only marginally above 50", "severity": "minor", "fields": ["m5.rsi"]}],
    "reject_reasons": [],
    "summary": "Aligned trend, valid support, momentum resuming.",
}


class FakeReviewer:
    def __init__(self, output=None, error: Exception | None = None):
        self.output, self.error, self.calls = output, error, 0

    def review(self, system, tool, user_text):
        self.calls += 1
        assert tool["name"] == "submit_verdict"
        assert "<candidate>" in user_text
        if self.error:
            raise self.error
        return ReviewResult(tool_input=self.output, usage={"input_tokens": 4000, "output_tokens": 600},
                            model="claude-sonnet-5-5", raw={})


def make(tmp_path, reviewer, **kw):
    s = Settings(api_key="sk-test", ea_token=TOKEN, log_dir=str(tmp_path), **kw)
    return build_service(s, reviewer)


def post(svc, body, token=TOKEN):
    return svc.handle(token, json.dumps(body).encode())


def test_confirm_path(tmp_path):
    svc = make(tmp_path, FakeReviewer(GOOD_CONFIRM))
    code, out = post(svc, candidate())
    assert code == 200 and out["decision"] == "CONFIRM"
    assert out["candidate_id"] == "GE-1793512277-BUY" and out["schema"] == "verdict.v1"
    log = (tmp_path / "ai_calls.jsonl").read_text()
    assert "sk-test" not in log and TOKEN not in log


def test_bad_token(tmp_path):
    rv = FakeReviewer(GOOD_CONFIRM)
    svc = make(tmp_path, rv)
    assert post(svc, candidate(), token="wrong")[0] == 401
    assert post(svc, candidate(), token=None)[0] == 401
    assert rv.calls == 0


def test_invalid_candidate_rejected_before_api(tmp_path):
    rv = FakeReviewer(GOOD_CONFIRM)
    svc = make(tmp_path, rv)
    bad = candidate()
    bad["proposal"]["sl"] = 4005.0            # SL above entry on a BUY
    assert post(svc, bad)[0] == 400
    bad2 = candidate()
    bad2["proposal"]["risk_pct"] = 0.9        # over the 0.5% project limit
    assert post(svc, bad2)[0] == 400
    bad3 = candidate()
    bad3["proposal"]["rr"] = 1.5
    assert post(svc, bad3)[0] == 400
    assert rv.calls == 0


def test_major_contradiction_overrides_confirm(tmp_path):
    out = json.loads(json.dumps(GOOD_CONFIRM))
    out["contradictions"].append({"issue": "Target behind H1 resistance", "severity": "major", "fields": ["levels.0.high"]})
    code, res = post(make(tmp_path, FakeReviewer(out)), candidate())
    assert code == 200 and res["decision"] == "REJECT" and "overridden" in res["summary"]


def test_invented_field_forces_reject(tmp_path):
    out = json.loads(json.dumps(GOOD_CONFIRM))
    out["evidence"][0]["fields"] = ["h1.vwap"]       # not in the input
    code, res = post(make(tmp_path, FakeReviewer(out)), candidate())
    assert res["decision"] == "REJECT"


def test_thin_confirm_rejected(tmp_path):
    out = json.loads(json.dumps(GOOD_CONFIRM))
    out["evidence"] = out["evidence"][:1]
    assert post(make(tmp_path, FakeReviewer(out)), candidate())[1]["decision"] == "REJECT"


def test_malformed_tool_output_rejected(tmp_path):
    code, res = post(make(tmp_path, FakeReviewer({"decision": "BUY_NOW", "summary": "x"})), candidate())
    assert code == 200 and res["decision"] == "REJECT"
    extra = dict(GOOD_CONFIRM, new_sl=3990.0)       # trying to modify the trade -> schema forbids extras
    assert post(make(tmp_path / "b", FakeReviewer(extra)), candidate("GE-2-BUY-x"))[1]["decision"] == "REJECT"


def test_review_error_is_503(tmp_path):
    svc = make(tmp_path, FakeReviewer(error=ReviewError("transport: Timeout")))
    assert post(svc, candidate())[0] == 503


def test_idempotent_single_api_call(tmp_path):
    rv = FakeReviewer(GOOD_CONFIRM)
    svc = make(tmp_path, rv)
    a, b = post(svc, candidate()), post(svc, candidate())
    assert a == b and rv.calls == 1


def test_daily_cap(tmp_path):
    rv = FakeReviewer(GOOD_CONFIRM)
    svc = make(tmp_path, rv, max_calls_per_day=2)
    assert post(svc, candidate("GE-a-BUY-1"))[0] == 200
    assert post(svc, candidate("GE-a-BUY-2"))[0] == 200
    assert post(svc, candidate("GE-a-BUY-3"))[0] == 503
    assert rv.calls == 2


def test_monthly_budget_cap(tmp_path):
    rv = FakeReviewer(GOOD_CONFIRM)
    # each fake call costs 4000*2/1e6 + 600*10/1e6 = 0.014 USD
    svc = make(tmp_path, rv, max_usd_per_month=0.02)
    assert post(svc, candidate("GE-b-BUY-1"))[0] == 200
    assert post(svc, candidate("GE-b-BUY-2"))[0] == 200   # 0.014 < 0.02 so allowed
    assert post(svc, candidate("GE-b-BUY-3"))[0] == 503   # 0.028 >= 0.02 blocked


def test_sell_geometry(tmp_path):
    out = json.loads(json.dumps(GOOD_CONFIRM))
    assert post(make(tmp_path, FakeReviewer(out)), candidate("GE-9-SELL", "SELL"))[0] == 200


def test_path_resolution():
    c = candidate()
    assert path_exists(c, "bars.m5.0.4")
    assert path_exists(c, "levels[0].touches")
    assert not path_exists(c, "levels.5.touches")
    assert not path_exists(c, "h1.swings.0.volume")


def test_settings_refuse_public_bind():
    with pytest.raises(ValueError):
        Settings(api_key="k", ea_token=TOKEN, host="0.0.0.0").validate()
    with pytest.raises(ValueError):
        Settings(api_key="k", ea_token="short").validate()
    with pytest.raises(ValueError):
        Settings(api_key="", ea_token=TOKEN).validate()


def test_claude_client_parses_tool_call(monkeypatch):
    class Resp:
        status_code = 200
        text = ""
        def json(self):
            return {"model": "claude-sonnet-5-5", "stop_reason": "tool_use",
                    "content": [{"type": "tool_use", "name": "submit_verdict", "input": GOOD_CONFIRM}],
                    "usage": {"input_tokens": 10, "output_tokens": 5}}

    class Sess:
        def post(self, url, json=None, headers=None, timeout=None):
            assert headers["x-api-key"] == "k" and json["tool_choice"]["name"] == "submit_verdict"
            assert json["system"][0]["cache_control"]["type"] == "ephemeral"
            return Resp()

    r = ClaudeClient("k", "claude-sonnet-5-5", 5, session=Sess()).review("sys", {"name": "submit_verdict"}, "u")
    assert r.tool_input["decision"] == "CONFIRM" and r.usage["output_tokens"] == 5


def test_claude_client_text_reply_is_error():
    class Resp:
        status_code = 200
        text = ""
        def json(self):
            return {"content": [{"type": "text", "text": "I think buy"}], "stop_reason": "end_turn"}

    class Sess:
        def post(self, *a, **k):
            return Resp()

    with pytest.raises(ReviewError):
        ClaudeClient("k", "m", 5, session=Sess()).review("s", {"name": "submit_verdict"}, "u")


def test_http_roundtrip(tmp_path):
    svc = make(tmp_path, FakeReviewer(GOOD_CONFIRM))
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(svc))
    th = threading.Thread(target=httpd.serve_forever, daemon=True)
    th.start()
    try:
        url = f"http://127.0.0.1:{httpd.server_address[1]}"
        r = requests.post(url + "/v1/review", data=json.dumps(candidate()),
                          headers={"X-EA-Token": TOKEN, "Content-Type": "application/json"}, timeout=5)
        assert r.status_code == 200 and r.json()["decision"] == "CONFIRM"
        assert requests.get(url + "/health", timeout=5).json()["status"] == "ok"
        assert requests.post(url + "/v1/review", data="{}", headers={"X-EA-Token": "x"}, timeout=5).status_code == 401
    finally:
        httpd.shutdown()
