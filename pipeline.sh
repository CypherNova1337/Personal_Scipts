#!/usr/bin/env bash
#
# pipeline.sh — run the full recon → probe → URL/JS → scan chain for a target.
#
# Stages (each skips gracefully if its tools are missing):
#   1. subenum      subdomains         -> <out>/subdomains/all_subdomains.txt
#   2. probe        live HTTP services -> <out>/probe/live.txt
#   3. urlcollect   historical URLs    -> <out>/urls/all_urls.txt
#   4. jsrecon      JS endpoints/secrets
#   5. nuclei       vuln scan on live services (only with --scan)
#
# Usage:
#   ./pipeline.sh example.com
#   ./pipeline.sh -l domains.txt -o engagement_x --scan
#   ./pipeline.sh example.com --crawl --scan
#
# Only run this against assets you are authorized to test.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

OUT_DIR="pipeline_output"
LIST=""
SINGLE=""
CRAWL=""
SCAN=0

usage() {
  cat <<EOF
Usage: $0 [options] <domain>
       $0 [options] -l <domains-file>

Options:
  -l, --list <file>   Domains file, one per line.
  -o, --output <dir>  Base output directory (default: $OUT_DIR).
      --crawl         Include active katana crawl in URL collection.
      --scan          Run the nuclei stage at the end.
  -h, --help          Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list)   LIST="$2"; shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    --crawl)     CRAWL="--crawl"; shift ;;
    --scan)      SCAN=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          err "Unknown option: $1"; usage; exit 1 ;;
    *)           SINGLE="$1"; shift ;;
  esac
done

[ -n "$LIST" ] || [ -n "$SINGLE" ] || { err "Provide a domain or -l <file>."; usage; exit 1; }
mkdir -p "$OUT_DIR"

# Build the target argument set once, reused by each stage.
if [ -n "$LIST" ]; then TARGET_ARGS=(-l "$LIST"); else TARGET_ARGS=("$SINGLE"); fi

echo "==================================================================="
info "recon pipeline starting  (output: $OUT_DIR)"
echo "==================================================================="

# --- Stage 1: subdomains ---------------------------------------------------
info "[1/5] subdomain enumeration"
bash "$SCRIPT_DIR/recon/subenum.sh" "${TARGET_ARGS[@]}" -o "$OUT_DIR/subdomains" || warn "subenum stage had errors"
SUBS="$OUT_DIR/subdomains/all_subdomains.txt"
[ -s "$SUBS" ] || { warn "no subdomains found; seeding probe with the raw target(s)";
  if [ -n "$LIST" ]; then cp "$LIST" "$OUT_DIR/seed.txt"; else printf '%s\n' "$SINGLE" > "$OUT_DIR/seed.txt"; fi
  SUBS="$OUT_DIR/seed.txt"; }

# --- Stage 2: live probing -------------------------------------------------
info "[2/5] probing for live services"
bash "$SCRIPT_DIR/recon/probe.sh" -i "$SUBS" -o "$OUT_DIR/probe" || warn "probe stage had errors"
LIVE="$OUT_DIR/probe/live.txt"

# --- Stage 3: URL collection ----------------------------------------------
info "[3/5] collecting URLs"
if [ -s "$LIVE" ]; then
  bash "$SCRIPT_DIR/recon/urlcollect.sh" -l "$LIVE" -o "$OUT_DIR/urls" $CRAWL || warn "urlcollect stage had errors"
else
  warn "no live hosts — running urlcollect on subdomains instead"
  bash "$SCRIPT_DIR/recon/urlcollect.sh" -l "$SUBS" -o "$OUT_DIR/urls" $CRAWL || warn "urlcollect stage had errors"
fi
URLS="$OUT_DIR/urls/all_urls.txt"

# --- Stage 4: JS recon -----------------------------------------------------
info "[4/5] JS endpoint/secret mining"
if [ -s "$URLS" ]; then
  bash "$SCRIPT_DIR/recon/jsrecon.sh" -i "$URLS" -o "$OUT_DIR/js" || warn "jsrecon stage had errors"
else
  warn "no URLs collected — skipping JS recon"
fi

# --- Stage 5: nuclei -------------------------------------------------------
if [ "$SCAN" -eq 1 ]; then
  info "[5/5] nuclei scan"
  if [ -s "$LIVE" ]; then
    bash "$SCRIPT_DIR/exploit/nuclei-scan.sh" -i "$LIVE" -o "$OUT_DIR/nuclei" || warn "nuclei stage had errors"
  else
    warn "no live hosts — skipping nuclei"
  fi
else
  info "[5/5] nuclei scan skipped (pass --scan to enable)"
fi

echo "==================================================================="
good "pipeline complete — results under $OUT_DIR/"
echo "==================================================================="
