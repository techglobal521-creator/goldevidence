"""Configuration for the GoldEvidence Claude review service.

Secrets come ONLY from environment variables (or the OS keyring if the
optional `keyring` package is installed). Nothing secret is read from
files in the repository.

Environment variables
---------------------
ANTHROPIC_API_KEY     Anthropic API key (required unless stored in keyring)
GE_EA_TOKEN           Shared secret the EA sends in X-EA-Token (required, >= 16 chars)
GE_MODEL              Pinned model id (default: claude-sonnet-5-5)
GE_HOST / GE_PORT     Bind address (must be loopback) / port (default 127.0.0.1:8787)
GE_TIMEOUT_S          Claude API timeout seconds (default 15)
GE_MAX_CALLS_PER_DAY  Hard cap on Claude calls per UTC day (default 20)
GE_MAX_USD_PER_MONTH  Hard monthly spend cap in USD (default 3.00)
GE_PRICE_IN_PER_MTOK  USD per 1M input tokens  (default 2.00 - verify current pricing)
GE_PRICE_OUT_PER_MTOK USD per 1M output tokens (default 10.00 - verify current pricing)
GE_LOG_DIR            Directory for audit logs and usage state (default ./ge_logs)
"""
from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass


def _get_api_key() -> str:
    key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    if key:
        return key
    try:  # optional: Windows Credential Manager / macOS Keychain via keyring
        import keyring  # type: ignore

        stored = keyring.get_password("goldevidence", "anthropic_api_key")
        return (stored or "").strip()
    except Exception:
        return ""


@dataclass(frozen=True)
class Settings:
    api_key: str
    ea_token: str
    model: str = "claude-sonnet-5-5"
    host: str = "127.0.0.1"
    port: int = 8787
    timeout_s: float = 15.0
    max_tokens: int = 1500
    max_calls_per_day: int = 20
    max_usd_per_month: float = 3.0
    price_in_per_mtok: float = 2.0
    price_out_per_mtok: float = 10.0
    log_dir: str = "ge_logs"

    def validate(self) -> None:
        if not self.api_key:
            raise ValueError("ANTHROPIC_API_KEY is not set (env var or keyring 'goldevidence/anthropic_api_key')")
        if len(self.ea_token) < 16:
            raise ValueError("GE_EA_TOKEN must be set and at least 16 characters")
        if not ipaddress.ip_address(self.host).is_loopback:
            raise ValueError("GE_HOST must be a loopback address; the service must never be exposed to the network")
        if self.max_calls_per_day < 1 or self.max_usd_per_month <= 0:
            raise ValueError("caps must be positive")

    def redacted(self) -> dict:
        return {
            "model": self.model, "host": self.host, "port": self.port, "timeout_s": self.timeout_s,
            "max_calls_per_day": self.max_calls_per_day, "max_usd_per_month": self.max_usd_per_month,
            "price_in_per_mtok": self.price_in_per_mtok, "price_out_per_mtok": self.price_out_per_mtok,
            "log_dir": self.log_dir, "api_key": "***set***" if self.api_key else "MISSING",
            "ea_token": "***set***" if self.ea_token else "MISSING",
        }


def load_settings() -> Settings:
    env = os.environ
    return Settings(
        api_key=_get_api_key(),
        ea_token=env.get("GE_EA_TOKEN", "").strip(),
        model=env.get("GE_MODEL", "claude-sonnet-5-5"),
        host=env.get("GE_HOST", "127.0.0.1"),
        port=int(env.get("GE_PORT", "8787")),
        timeout_s=float(env.get("GE_TIMEOUT_S", "15")),
        max_calls_per_day=int(env.get("GE_MAX_CALLS_PER_DAY", "20")),
        max_usd_per_month=float(env.get("GE_MAX_USD_PER_MONTH", "3.0")),
        price_in_per_mtok=float(env.get("GE_PRICE_IN_PER_MTOK", "2.0")),
        price_out_per_mtok=float(env.get("GE_PRICE_OUT_PER_MTOK", "10.0")),
        log_dir=env.get("GE_LOG_DIR", "ge_logs"),
    )
