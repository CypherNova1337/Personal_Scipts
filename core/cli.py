"""
cli — argparse scaffolding shared by the Python scanners.

Gives every tool the same input model (positional targets, -i/--input file or
stdin, '-' for stdin) and the same engine tuning flags, so they compose.
"""

from __future__ import annotations

import argparse
import os
import sys
from typing import Iterator, Optional

from .engine import Engine, EngineConfig
from .findings import Reporter, Severity


def base_parser(description: str, with_targets: bool = True) -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=description,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    tgt = p.add_argument_group("targets")
    # When with_targets is False the caller adds its own positionals first (so a
    # leading subcommand isn't shadowed) and adds the targets positional itself.
    if with_targets:
        tgt.add_argument("targets", nargs="*", help="Target URL(s)/host(s).")
    tgt.add_argument("-i", "--input",
                     help="File of targets, one per line ('-' for stdin).")

    eng = p.add_argument_group("engine")
    eng.add_argument("-c", "--concurrency", type=int, default=50,
                     help="Max concurrent requests (default: 50).")
    eng.add_argument("--rate", type=float, default=0.0,
                     help="Global requests/sec cap (0 = unlimited).")
    eng.add_argument("--timeout", type=float, default=15.0,
                     help="Per-request timeout seconds (default: 15).")
    eng.add_argument("--retries", type=int, default=2,
                     help="Retries after the first attempt (default: 2).")
    eng.add_argument("-H", "--header", action="append", default=[], metavar="K:V",
                     help="Extra header sent on every request (repeatable).")
    eng.add_argument("--proxy", help="HTTP(S) proxy URL, e.g. http://127.0.0.1:8080.")
    eng.add_argument("-k", "--insecure", action="store_true",
                     help="Disable TLS verification.")
    eng.add_argument("--http2", action="store_true",
                     help="Enable HTTP/2 (requires the 'h2' package).")
    eng.add_argument("-A", "--user-agent", help="Override the User-Agent.")

    out = p.add_argument_group("output")
    out.add_argument("-o", "--output", help="Write findings as JSONL to this file.")
    out.add_argument("--min-severity", default="INFO",
                     choices=[s.name for s in Severity],
                     help="Console threshold (default: INFO). JSONL always full.")
    out.add_argument("-q", "--quiet", action="store_true",
                     help="Suppress the per-finding console lines.")
    return p


def _parse_headers(pairs: list[str]) -> dict[str, str]:
    headers: dict[str, str] = {}
    for item in pairs:
        if ":" not in item:
            sys.exit(f"[x] bad -H value (want 'Key: Value'): {item}")
        k, v = item.split(":", 1)
        headers[k.strip()] = v.strip()
    return headers


def load_targets(args: argparse.Namespace) -> list[str]:
    """Collect targets from positionals, -i file, and/or stdin. Deduped, order-preserving."""
    seen: set[str] = set()
    out: list[str] = []

    def add(line: str) -> None:
        t = line.strip()
        if not t or t.startswith("#") or t in seen:
            return
        seen.add(t)
        out.append(t)

    for t in args.targets:
        add(t)

    src: Optional[Iterator[str]] = None
    if args.input == "-" or (not args.targets and not args.input and not sys.stdin.isatty()):
        src = sys.stdin
    elif args.input:
        if not os.path.isfile(args.input):
            sys.exit(f"[x] input file not found: {args.input}")
        src = open(args.input, encoding="utf-8", errors="replace")
    if src is not None:
        for line in src:
            add(line)
        if src is not sys.stdin:
            src.close()

    return out


def engine_from_args(args: argparse.Namespace) -> Engine:
    cfg = EngineConfig(
        concurrency=args.concurrency,
        rate=args.rate,
        timeout=args.timeout,
        retries=args.retries,
        verify_tls=not args.insecure,
        http2=args.http2,
        proxy=args.proxy,
        default_headers=_parse_headers(args.header),
    )
    if args.user_agent:
        cfg.user_agent = args.user_agent
    return Engine(cfg)


def reporter_from_args(args: argparse.Namespace) -> Reporter:
    return Reporter(
        jsonl_path=args.output,
        min_severity=Severity.parse(args.min_severity),
        quiet=args.quiet,
    )
