"""Minimal Anthropic Messages API client (HTTPS via `requests`).

The verdict is forced through a tool call (tool_choice = submit_verdict), so a
free-text answer is impossible. The static system prompt is marked for prompt
caching to reduce cost on repeated calls.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

import requests

API_URL = "https://api.anthropic.com/v1/messages"
API_VERSION = "2023-06-01"


class ReviewError(Exception):
    """Transport or protocol failure. The service maps this to 'not confirmed'."""


@dataclass
class ReviewResult:
    tool_input: dict[str, Any]
    usage: dict[str, int]
    model: str
    raw: dict[str, Any]


class Reviewer(Protocol):
    def review(self, system: str, tool: dict[str, Any], user_text: str) -> ReviewResult: ...


class ClaudeClient:
    def __init__(self, api_key: str, model: str, timeout_s: float, max_tokens: int = 1500,
                 session: requests.Session | None = None) -> None:
        self._key = api_key
        self.model = model
        self.timeout_s = timeout_s
        self.max_tokens = max_tokens
        self._http = session or requests.Session()

    def review(self, system: str, tool: dict[str, Any], user_text: str) -> ReviewResult:
        body = {
            "model": self.model,
            "max_tokens": self.max_tokens,
            "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            "tools": [tool],
            "tool_choice": {"type": "tool", "name": tool["name"]},
            "messages": [{"role": "user", "content": user_text}],
        }
        headers = {"x-api-key": self._key, "anthropic-version": API_VERSION, "content-type": "application/json"}
        try:
            resp = self._http.post(API_URL, json=body, headers=headers, timeout=self.timeout_s)
        except requests.RequestException as exc:  # timeout, DNS, TLS ...
            raise ReviewError(f"transport: {type(exc).__name__}") from exc
        if resp.status_code != 200:
            # never echo request headers; the response body contains no secrets
            raise ReviewError(f"http {resp.status_code}: {resp.text[:300]}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise ReviewError("response is not JSON") from exc
        blocks = [b for b in data.get("content", []) if b.get("type") == "tool_use" and b.get("name") == tool["name"]]
        if len(blocks) != 1 or not isinstance(blocks[0].get("input"), dict):
            raise ReviewError(f"expected exactly one {tool['name']} tool call, stop_reason={data.get('stop_reason')}")
        usage = data.get("usage", {}) or {}
        return ReviewResult(
            tool_input=blocks[0]["input"],
            usage={k: int(v) for k, v in usage.items() if isinstance(v, (int, float))},
            model=str(data.get("model", self.model)),
            raw=data,
        )
