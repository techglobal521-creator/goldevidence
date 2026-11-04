"""Request / response schemas.

candidate.v1  EA -> service   (validated strictly on the fields the reviewer relies on)
verdict tool  Claude -> service (forced tool call; validated again here)
verdict.v1    service -> EA   (flat object the EA can parse without a JSON library)
"""
from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class Proposal(BaseModel):
    model_config = ConfigDict(extra="allow")
    entry: float = Field(gt=0)
    sl: float = Field(gt=0)
    tp: float = Field(gt=0)
    rr: float = Field(ge=2.0)
    risk_pct: float = Field(gt=0, le=0.5)


class Candidate(BaseModel):
    """Only the core fields are typed; everything else is passed through to Claude as data."""

    model_config = ConfigDict(extra="allow")
    schema_: Literal["candidate.v1"] = Field(alias="schema")
    candidate_id: str = Field(min_length=6, max_length=64)
    direction: Literal["BUY", "SELL"]
    symbol: str
    server_time: str
    proposal: Proposal
    market: dict[str, Any]
    h1: dict[str, Any]
    m15: dict[str, Any]
    m5: dict[str, Any]
    setup: dict[str, Any]
    levels: list[dict[str, Any]]
    bars: dict[str, Any]

    @model_validator(mode="after")
    def _geometry(self) -> "Candidate":
        p = self.proposal
        if self.direction == "BUY" and not (p.sl < p.entry < p.tp):
            raise ValueError("BUY requires sl < entry < tp")
        if self.direction == "SELL" and not (p.tp < p.entry < p.sl):
            raise ValueError("SELL requires tp < entry < sl")
        return self


class EvidenceItem(BaseModel):
    claim: str = Field(min_length=3, max_length=400)
    fields: list[str] = Field(min_length=1, max_length=12)


class Contradiction(BaseModel):
    issue: str = Field(min_length=3, max_length=400)
    severity: Literal["minor", "major"]
    fields: list[str] = Field(min_length=1, max_length=12)


class ToolVerdict(BaseModel):
    """What Claude must return through the forced `submit_verdict` tool."""

    model_config = ConfigDict(extra="forbid")
    decision: Literal["CONFIRM", "REJECT"]
    evidence: list[EvidenceItem] = Field(default_factory=list, max_length=12)
    contradictions: list[Contradiction] = Field(default_factory=list, max_length=12)
    reject_reasons: list[str] = Field(default_factory=list, max_length=12)
    summary: str = Field(min_length=3, max_length=300)

    @field_validator("reject_reasons")
    @classmethod
    def _short(cls, v: list[str]) -> list[str]:
        return [s[:300] for s in v]


class VerdictOut(BaseModel):
    schema_: Literal["verdict.v1"] = Field(default="verdict.v1", alias="schema")
    candidate_id: str
    decision: Literal["CONFIRM", "REJECT"]
    summary: str
    model: str = ""
    latency_ms: int = 0

    def to_json_dict(self) -> dict[str, Any]:
        return self.model_dump(by_alias=True)
