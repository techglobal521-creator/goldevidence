"""HTTP front-end (standard library only), bound to loopback.

Run:  python -m ai_service
Endpoints:
  POST /v1/review   header X-EA-Token, body candidate.v1 JSON
  GET  /health      liveness + usage snapshot (no secrets)
"""
from __future__ import annotations

import json
import logging
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .audit_log import AuditLog
from .budget import Budget
from .claude_client import ClaudeClient
from .config import Settings, load_settings
from .service import MAX_BODY_BYTES, ReviewService

log = logging.getLogger("goldevidence")


def make_handler(service: ReviewService):
    class Handler(BaseHTTPRequestHandler):
        server_version = "GoldEvidence/1.0"

        def _send(self, code: int, obj: dict) -> None:
            body = json.dumps(obj).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if self.path == "/health":
                self._send(200, {"status": "ok", "model": service.model, "usage": service.budget.snapshot()})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/v1/review":
                self._send(404, {"error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = -1
            if length < 0 or length > MAX_BODY_BYTES:
                self._send(413, {"error": "bad length"})
                return
            raw = self.rfile.read(length)
            try:
                code, obj = service.handle(self.headers.get("X-EA-Token"), raw)
            except Exception:  # never crash, never leak internals; EA treats non-200 as no-trade
                log.exception("unhandled error")
                code, obj = 503, {"error": "internal error"}
            self._send(code, obj)

        def log_message(self, fmt: str, *args) -> None:  # route to logging, without headers
            log.info("%s %s", self.address_string(), fmt % args)

    return Handler


def build_service(settings: Settings, reviewer=None) -> ReviewService:
    os.makedirs(settings.log_dir, exist_ok=True)
    budget = Budget(os.path.join(settings.log_dir, "usage_state.json"), settings.max_calls_per_day,
                    settings.max_usd_per_month, settings.price_in_per_mtok, settings.price_out_per_mtok)
    reviewer = reviewer or ClaudeClient(settings.api_key, settings.model, settings.timeout_s, settings.max_tokens)
    return ReviewService(reviewer, settings.ea_token, budget, AuditLog(settings.log_dir), settings.model)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    settings = load_settings()
    settings.validate()
    service = build_service(settings)
    httpd = ThreadingHTTPServer((settings.host, settings.port), make_handler(service))
    log.info("GoldEvidence review service listening on http://%s:%d  config=%s",
             settings.host, settings.port, settings.redacted())
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
