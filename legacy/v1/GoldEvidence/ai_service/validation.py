"""Server-side checks on Claude's verdict. Any failure -> REJECT.

- the verdict must parse against the strict schema
- every cited field path must exist in the candidate (catches invented data)
- any 'major' contradiction forces REJECT even if Claude said CONFIRM
- CONFIRM must cite at least 3 pieces of evidence
"""
from __future__ import annotations

from typing import Any

from pydantic import ValidationError

from .schemas import ToolVerdict

_MISSING = object()


def resolve_path(obj: Any, path: str) -> Any:
    """Resolve 'a.b.3.c' (numeric segments index lists). Also accepts 'a.b[3].c'."""
    cur = obj
    norm = path.replace("[", ".").replace("]", "").strip(".")
    if not norm:
        return _MISSING
    for seg in norm.split("."):
        if isinstance(cur, dict):
            if seg not in cur:
                return _MISSING
            cur = cur[seg]
        elif isinstance(cur, list):
            if not seg.lstrip("-").isdigit():
                return _MISSING
            i = int(seg)
            if i < -len(cur) or i >= len(cur):
                return _MISSING
            cur = cur[i]
        else:
            return _MISSING
    return cur


def path_exists(obj: Any, path: str) -> bool:
    return resolve_path(obj, path) is not _MISSING


def finalize(candidate: dict[str, Any], tool_input: dict[str, Any]) -> tuple[str, str, list[str]]:
    """Return (decision, summary, problems). decision is CONFIRM only if every check passes."""
    try:
        v = ToolVerdict.model_validate(tool_input)
    except ValidationError as exc:
        return "REJECT", "invalid verdict structure", [f"schema: {exc.error_count()} errors"]

    problems: list[str] = []
    cited = [f for e in v.evidence for f in e.fields] + [f for c in v.contradictions for f in c.fields]
    unknown = sorted({f for f in cited if not path_exists(candidate, f)})
    if unknown:
        problems.append("cited unknown fields: " + ", ".join(unknown[:8]))

    majors = [c.issue for c in v.contradictions if c.severity == "major"]
    if majors:
        problems.append("major contradiction: " + majors[0][:120])

    if v.decision == "CONFIRM" and len(v.evidence) < 3:
        problems.append("CONFIRM with fewer than 3 evidence items")

    if v.decision == "REJECT":
        return "REJECT", v.summary, problems
    if problems:
        return "REJECT", "overridden: " + problems[0], problems
    return "CONFIRM", v.summary, problems
