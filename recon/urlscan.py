#!/usr/bin/env python3
"""
urlscan.py — collect subdomains or URLs for a target from urlscan.io.

The API key is read from the URLSCAN_API_KEY environment variable so it is
never committed to the repo:

    export URLSCAN_API_KEY="your-key-here"

Usage:
    ./urlscan.py -m subdomains -d example.com
    ./urlscan.py -m urls -d example.com
    ./urlscan.py -m subdomains -df domains.txt

Based on an original script by coffinxp (see README credits).
"""

import argparse
import os
import re
import sys
import time

try:
    import requests
except ImportError:
    sys.exit("[x] Missing dependency: requests  (pip install requests)")

API_KEY = os.environ.get("URLSCAN_API_KEY", "")


def sanitize_domain(domain):
    domain = domain.strip().lower()
    domain = re.sub(r"^https?://", "", domain)
    domain = domain.split("/")[0]
    if not domain or domain.startswith("#"):
        return None
    return domain


def safe_request(url, headers):
    try:
        return requests.get(url, headers=headers, timeout=15)
    except requests.RequestException as exc:
        print(f"[!] request failed: {exc}", file=sys.stderr)
        return None


def scan_domain(domain, mode, api_key):
    domain = sanitize_domain(domain)
    if not domain:
        return []

    url = f"https://urlscan.io/api/v1/search/?q=page.domain:{domain}&size=100"
    headers = {"API-Key": api_key} if api_key else {}
    response = safe_request(url, headers)
    if not response or response.status_code != 200:
        code = response.status_code if response else "no response"
        print(f"[!] {domain}: urlscan returned {code}", file=sys.stderr)
        return []

    if mode == "subdomains":
        matched = re.findall(
            rf"https?://((?:[a-zA-Z0-9_-]+\.)+{re.escape(domain)})", response.text
        )
        results = [m.split("/")[0] for m in matched if m != domain]
    else:  # urls
        results = re.findall(
            rf"https?://(?:[a-zA-Z0-9_-]+\.)+{re.escape(domain)}/[^\s\"'>]+",
            response.text,
        )

    return sorted(set(results))


def main():
    parser = argparse.ArgumentParser(description="Collect data from urlscan.io.")
    parser.add_argument("-m", "--mode", required=True, choices=["subdomains", "urls"],
                        help="What to collect.")
    parser.add_argument("-d", "--domain", help="Single domain to scan.")
    parser.add_argument("-df", "--domain-file", help="File of domains, one per line.")
    args = parser.parse_args()

    if not API_KEY:
        print("[!] URLSCAN_API_KEY not set — running unauthenticated "
              "(heavier rate limits).", file=sys.stderr)

    if args.domain:
        domains = [args.domain]
    elif args.domain_file:
        if not os.path.isfile(args.domain_file):
            sys.exit(f"[x] File not found: {args.domain_file}")
        with open(args.domain_file, encoding="utf-8") as fh:
            domains = [line for line in fh]
    else:
        sys.exit("[x] Provide a domain (-d) or a domain file (-df).")

    for i, domain in enumerate(domains):
        for item in scan_domain(domain, args.mode, API_KEY):
            print(item)
        if i < len(domains) - 1:
            time.sleep(2)  # be polite to the API


if __name__ == "__main__":
    main()
