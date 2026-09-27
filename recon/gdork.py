#!/usr/bin/env python3
"""
gdork.py — run a Google dork query and collect the result URLs.

Works from CLI flags (scriptable) or, with no query given, interactively.

    ./gdork.py -q 'site:example.com inurl:admin' -n 50
    ./gdork.py -q 'site:example.com ext:sql' --all -o out.txt
    ./gdork.py            # prompts for the query

Requires: pip install googlesearch-python

Note: Google aggressively rate-limits automated searching. Keep result
counts modest and expect occasional HTTP 429s.
"""

import argparse
import sys
import time

try:
    from googlesearch import search
except ImportError:
    sys.exit("[x] Missing dependency: googlesearch-python  "
             "(pip install googlesearch-python)")


def run(query, limit, outfile, pause):
    print(f"[*] searching: {query}")
    fh = open(outfile, "a", encoding="utf-8") if outfile else None
    count = 0
    try:
        for result in search(query):
            if limit is not None and count >= limit:
                break
            print(result)
            if fh:
                fh.write(result + "\n")
            count += 1
            if pause:
                time.sleep(pause)
    except KeyboardInterrupt:
        print("\n[!] interrupted", file=sys.stderr)
    except Exception as exc:  # googlesearch raises plain Exceptions on 429 etc.
        print(f"[!] search error after {count} results: {exc}", file=sys.stderr)
    finally:
        if fh:
            fh.close()
    print(f"[+] done — {count} results" + (f" saved to {outfile}" if outfile else ""))


def main():
    p = argparse.ArgumentParser(description="Google dork runner.")
    p.add_argument("-q", "--query", help="Dork query. Omit to be prompted.")
    p.add_argument("-n", "--num", type=int, default=30,
                   help="Max results (default: 30).")
    p.add_argument("--all", action="store_true",
                   help="Fetch everything (overrides -n).")
    p.add_argument("-o", "--output", help="Append results to this file.")
    p.add_argument("--pause", type=float, default=1.0,
                   help="Seconds to sleep between results (default: 1.0).")
    args = p.parse_args()

    query = args.query or input("[+] Enter the dork query: ").strip()
    if not query:
        sys.exit("[x] No query provided.")

    limit = None if args.all else args.num
    run(query, limit, args.output, args.pause)


if __name__ == "__main__":
    main()
