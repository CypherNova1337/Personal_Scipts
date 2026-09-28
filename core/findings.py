"""
findings — structured results, severity ordering, and reporting.

A Finding is the single currency every check emits. The Reporter renders
findings to a colored console and, optionally, to a JSONL file so results can be
diffed, piped, or ingested by other tooling.
"""

from __future__ import annotations

import dataclasses
import enum
import json
import os
import sys
import threading
import time
from typing import Any, Optional


class Severity(enum.IntEnum):
    """Ordered so `max(...)` and sorting behave intuitively."""
    INFO = 0
    LOW = 1
    MEDIUM = 2
    HIGH = 3
    CRITICAL = 4

    @classmethod
    def parse(cls, name: str) -> "Severity":
        return cls[name.strip().upper()]

    def __str__(self) -> str:  # noqa: D401
        return self.name


_COLORS = {
    Severity.INFO: "\033[2m",       # dim
    Severity.LOW: "\033[36m",       # cyan
    Severity.MEDIUM: "\033[33m",    # yellow
    Severity.HIGH: "\033[31m",      # red
    Severity.CRITICAL: "\033[1;31m",  # bold red
}
_RESET = "\033[0m"


def _use_color(stream) -> bool:
    return stream.isatty() and os.environ.get("NO_COLOR") is None


@dataclasses.dataclass(slots=True)
class Finding:
    """A single result from a check."""
    check: str                       # e.g. "cors", "open-redirect"
    target: str                      # the URL/host the finding is about
    severity: Severity
    title: str                       # short human summary
    evidence: dict[str, Any] = dataclasses.field(default_factory=dict)
    payload: Optional[str] = None    # the input that triggered it, if any
    timestamp: float = dataclasses.field(default_factory=time.time)

    def to_dict(self) -> dict[str, Any]:
        d = dataclasses.asdict(self)
        d["severity"] = str(self.severity)
        return d

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), separators=(",", ":"), default=str)

    def console_line(self, color: bool) -> str:
        sev = f"[{self.severity}]"
        if color:
            sev = f"{_COLORS[self.severity]}{sev}{_RESET}"
        extra = ""
        if self.payload:
            extra = f"  payload={self.payload}"
        elif self.evidence:
            # Show the most useful one or two evidence keys inline.
            bits = [f"{k}={v}" for k, v in list(self.evidence.items())[:2]]
            extra = "  " + "  ".join(bits)
        return f"{sev} {self.check}: {self.target}  {self.title}{extra}"


class Reporter:
    """
    Thread/async-safe sink for findings.

    Writes a colored line to the console (>= min_severity) and, if a path is
    given, every finding as JSONL. Also keeps counts for a final summary.
    """

    def __init__(
        self,
        jsonl_path: Optional[str] = None,
        min_severity: Severity = Severity.INFO,
        quiet: bool = False,
        stream=sys.stdout,
    ):
        self._lock = threading.Lock()
        self._stream = stream
        self._color = _use_color(stream)
        self._min = min_severity
        self._quiet = quiet
        self._counts: dict[Severity, int] = {s: 0 for s in Severity}
        self.total = 0
        self._fh = open(jsonl_path, "a", encoding="utf-8") if jsonl_path else None
        self.jsonl_path = jsonl_path

    def report(self, finding: Finding) -> None:
        with self._lock:
            self.total += 1
            self._counts[finding.severity] += 1
            if self._fh:
                self._fh.write(finding.to_json() + "\n")
                self._fh.flush()
            if not self._quiet and finding.severity >= self._min:
                print(finding.console_line(self._color), file=self._stream, flush=True)

    def summary(self) -> str:
        parts = [f"{self._counts[s]} {s.name.lower()}"
                 for s in sorted(Severity, reverse=True) if self._counts[s]]
        body = ", ".join(parts) if parts else "no findings"
        tail = f"  ({self.jsonl_path})" if self.jsonl_path else ""
        return f"{self.total} finding(s): {body}{tail}"

    def close(self) -> None:
        if self._fh:
            self._fh.close()
            self._fh = None

    def __enter__(self) -> "Reporter":
        return self

    def __exit__(self, *exc) -> None:
        self.close()
