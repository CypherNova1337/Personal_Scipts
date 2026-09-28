#!/usr/bin/env python3
"""
secretscan.py — find hardcoded secrets in files using a rule set + entropy.

Two detection strategies, combined to keep signal high:

  1. Named rules  — tuned regexes for well-known credential formats (AWS, GCP,
     GitHub, Slack, Stripe, JWTs, private keys, etc.). High confidence.
  2. Entropy      — Shannon-entropy scoring of base64/hex-looking tokens catches
     unknown/rotated secrets that no rule covers, while thresholds + a stop-list
     suppress the obvious noise (hashes in URLs, minified var names, etc.).

Usage:
    ./secretscan.py file1.js file2.js
    ./secretscan.py -r ./js_output/files          # recurse a directory
    ./secretscan.py -i filelist.txt -o secrets.jsonl
    cat app.js | ./secretscan.py -                # scan stdin

Findings print as: [SEV] secret <file>:<line>  <rule>  <redacted match>
"""

from __future__ import annotations

import math
import os
import re
import sys
from typing import Iterator, Optional

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from core.findings import Finding, Reporter, Severity  # noqa: E402

# --- Named rules: (name, severity, compiled regex) -------------------------

_RULES_RAW = [
    ("aws-access-key-id", Severity.HIGH, r"(?<![A-Z0-9])(?:AKIA|ASIA|AROA|AIDA)[0-9A-Z]{16}(?![A-Z0-9])"),
    ("aws-secret-access-key", Severity.HIGH,
     r"(?i)aws.{0,20}?(?:secret|sk).{0,20}?['\"]([A-Za-z0-9/+=]{40})['\"]"),
    ("gcp-api-key", Severity.HIGH, r"AIza[0-9A-Za-z_\-]{35}"),
    ("github-token", Severity.HIGH, r"gh[pousr]_[0-9A-Za-z]{36,255}"),
    ("github-pat-fine", Severity.HIGH, r"github_pat_[0-9A-Za-z_]{22,255}"),
    ("slack-token", Severity.HIGH, r"xox[baprs]-[0-9A-Za-z-]{10,}"),
    ("slack-webhook", Severity.MEDIUM, r"https://hooks\.slack\.com/services/[A-Za-z0-9/]+"),
    ("stripe-secret", Severity.HIGH, r"(?:sk|rk)_(?:live|test)_[0-9A-Za-z]{24,}"),
    ("google-oauth", Severity.HIGH, r"ya29\.[0-9A-Za-z_\-]+"),
    ("private-key", Severity.CRITICAL, r"-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----"),
    ("jwt", Severity.MEDIUM, r"eyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"),
    ("twilio-sid", Severity.MEDIUM, r"AC[0-9a-fA-F]{32}"),
    ("sendgrid", Severity.HIGH, r"SG\.[0-9A-Za-z_\-]{22}\.[0-9A-Za-z_\-]{43}"),
    ("mailgun", Severity.HIGH, r"key-[0-9a-zA-Z]{32}"),
    ("npm-token", Severity.HIGH, r"npm_[0-9A-Za-z]{36}"),
    ("generic-assignment", Severity.LOW,
     r"(?i)(?:api[_-]?key|secret|token|passwd|password|auth|access[_-]?key)"
     r"['\"]?\s*[:=]\s*['\"]([^'\"\s]{8,})['\"]"),
]
RULES = [(n, s, re.compile(p)) for n, s, p in _RULES_RAW]

# Entropy detection.
_B64_TOKEN = re.compile(r"[A-Za-z0-9+/]{20,}={0,2}")
_HEX_TOKEN = re.compile(r"\b[0-9a-fA-F]{32,}\b")
B64_ENTROPY_MIN = 4.3      # bits/char; base64 max is 6.0
HEX_ENTROPY_MIN = 3.2      # hex max is 4.0

# Common tokens/paths that look random but rarely are secrets.
_STOPWORDS = re.compile(
    r"(?i)(sourcemappingurl|data:image|integrity=|sha256-|sha384-|sha512-|"
    r"webpack|node_modules|licenses?|copyright|application/|charset)")


def shannon_entropy(s: str) -> float:
    if not s:
        return 0.0
    counts: dict[str, int] = {}
    for ch in s:
        counts[ch] = counts.get(ch, 0) + 1
    n = len(s)
    return -sum((c / n) * math.log2(c / n) for c in counts.values())


def redact(match: str) -> str:
    m = match.strip("'\"")
    if len(m) <= 12:
        return m[:2] + "…"
    return f"{m[:4]}…{m[-4:]} (len {len(m)})"


def scan_line(line: str) -> Iterator[tuple[str, Severity, str]]:
    """Yield (rule, severity, matched-text) for each hit in one line."""
    seen: set[str] = set()

    for name, sev, rx in RULES:
        for m in rx.finditer(line):
            hit = m.group(1) if m.groups() else m.group(0)
            key = f"{name}:{hit}"
            if hit and key not in seen:
                seen.add(key)
                yield name, sev, hit

    if _STOPWORDS.search(line):
        return

    for rx, ent_min, label in ((_B64_TOKEN, B64_ENTROPY_MIN, "high-entropy-b64"),
                               (_HEX_TOKEN, HEX_ENTROPY_MIN, "high-entropy-hex")):
        for m in rx.finditer(line):
            tok = m.group(0)
            # Ignore very long blobs (likely embedded data, not a key).
            if len(tok) > 128:
                continue
            if shannon_entropy(tok) >= ent_min:
                key = f"{label}:{tok}"
                if key not in seen:
                    seen.add(key)
                    yield label, Severity.LOW, tok


def iter_files(paths: list[str], recurse: bool) -> Iterator[str]:
    for p in paths:
        if os.path.isdir(p):
            if recurse:
                for root, _dirs, files in os.walk(p):
                    for f in files:
                        yield os.path.join(root, f)
            else:
                for f in os.listdir(p):
                    fp = os.path.join(p, f)
                    if os.path.isfile(fp):
                        yield fp
        elif os.path.isfile(p):
            yield p


def scan_file(path: str, rep: Reporter, max_bytes: int = 5_000_000) -> None:
    try:
        if os.path.getsize(path) > max_bytes:
            return
        with open(path, encoding="utf-8", errors="replace") as fh:
            for lineno, line in enumerate(fh, 1):
                if len(line) > 20_000:      # avoid pathological minified lines
                    continue
                for rule, sev, hit in scan_line(line):
                    rep.report(Finding(
                        "secret", f"{path}:{lineno}", sev, rule,
                        evidence={"match": redact(hit)}))
    except OSError:
        pass


def main() -> None:
    import argparse
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("paths", nargs="*", help="Files/dirs to scan ('-' for stdin).")
    p.add_argument("-i", "--input", help="File listing paths to scan.")
    p.add_argument("-r", "--recurse", action="store_true", help="Recurse into directories.")
    p.add_argument("-o", "--output", help="Write findings as JSONL here.")
    p.add_argument("--min-severity", default="LOW",
                   choices=[s.name for s in Severity])
    p.add_argument("-q", "--quiet", action="store_true")
    args = p.parse_args()

    paths = list(args.paths)
    if args.input:
        with open(args.input, encoding="utf-8") as fh:
            paths += [ln.strip() for ln in fh if ln.strip()]

    rep = Reporter(jsonl_path=args.output,
                   min_severity=Severity.parse(args.min_severity),
                   quiet=args.quiet)
    try:
        if paths == ["-"] or (not paths and not sys.stdin.isatty()):
            for lineno, line in enumerate(sys.stdin, 1):
                for rule, sev, hit in scan_line(line):
                    rep.report(Finding("secret", f"<stdin>:{lineno}", sev, rule,
                                       evidence={"match": redact(hit)}))
        elif not paths:
            sys.exit("[x] no paths given (files/dirs, -i <list>, or stdin).")
        else:
            for fp in iter_files(paths, args.recurse):
                scan_file(fp, rep)
    finally:
        rep.close()
    print("[+] " + rep.summary(), file=sys.stderr)


if __name__ == "__main__":
    main()
