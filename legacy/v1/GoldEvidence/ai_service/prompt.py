"""Prompt and forced-output tool for the independent reviewer."""
from __future__ import annotations

import json
from typing import Any

SYSTEM_PROMPT = """You are an independent reviewer inside a risk-controlled XAUUSD (gold) trading research system.

A deterministic rule engine has ALREADY found a trade candidate and a separate risk engine has ALREADY sized it.
Your only job is to decide whether the evidence in the data supports the candidate well enough, or whether it should be rejected.
You can only CONFIRM or REJECT. You cannot change direction, entry, stop loss, take profit or size, and you must not suggest changes.

Rules you must follow:
1. Use ONLY the data in the candidate JSON. Do not use outside knowledge about gold prices, news, dates or events.
   Do not try to recall what happened in the market at these timestamps.
2. Never claim certainty about future prices. Speak about evidence, not predictions.
3. Every evidence item and every contradiction must cite the exact JSON field paths it is based on,
   using dot notation with numeric list indexes, e.g. "h1.ema50", "m5.rsi", "setup.zone_low", "levels.2.high", "bars.m5.47.4".
   Only cite paths that exist in the input.
4. Look specifically for contradictions, for example:
   - higher-timeframe trend that is stretched far from its EMAs or running into a nearby opposing level
   - momentum divergence (price making a new extreme while RSI does not)
   - the stop sitting inside an obvious cluster of recent wicks, or the target sitting behind a level
   - overlapping or conflicting zones near entry, very small or very large recent ranges, gaps in the bars
   - M15 or M5 behaviour that disagrees with the H1 bias
5. Mark a contradiction "major" if, on its own, it means the evidence is not sufficient for this trade. Otherwise "minor".
6. REJECT when evidence is incomplete, inconsistent, or when any major contradiction exists. Doubt means REJECT.
7. CONFIRM only when trend alignment, location (support/resistance or breakout-retest), momentum and the trigger
   are all clearly supported by the data and no major contradiction exists.
8. Respond only by calling the submit_verdict tool. Keep the summary under 40 words."""

VERDICT_TOOL: dict[str, Any] = {
    "name": "submit_verdict",
    "description": "Submit the review verdict for the trade candidate. This is the only allowed output.",
    "input_schema": {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "decision": {"type": "string", "enum": ["CONFIRM", "REJECT"]},
            "evidence": {
                "type": "array",
                "maxItems": 12,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "claim": {"type": "string"},
                        "fields": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 12},
                    },
                    "required": ["claim", "fields"],
                },
            },
            "contradictions": {
                "type": "array",
                "maxItems": 12,
                "items": {
                    "type": "object",
                    "additionalProperties": False,
                    "properties": {
                        "issue": {"type": "string"},
                        "severity": {"type": "string", "enum": ["minor", "major"]},
                        "fields": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 12},
                    },
                    "required": ["issue", "severity", "fields"],
                },
            },
            "reject_reasons": {"type": "array", "items": {"type": "string"}, "maxItems": 12},
            "summary": {"type": "string"},
        },
        "required": ["decision", "evidence", "contradictions", "reject_reasons", "summary"],
    },
}


def build_user_message(candidate: dict[str, Any]) -> str:
    """The candidate is passed verbatim as data. Bars are [time, open, high, low, close], oldest first."""
    return (
        "Review this rule-generated trade candidate. Bars are arrays of [time, open, high, low, close], oldest first, "
        "closed bars only. Prices are in the symbol's quote units. Distances such as atr_* and spread are in price units.\n\n"
        "<candidate>\n" + json.dumps(candidate, separators=(",", ":"), ensure_ascii=False) + "\n</candidate>"
    )
