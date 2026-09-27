#!/usr/bin/env bash
#
# urlcollect.sh — gather historical & crawled URLs for target(s) from several
# sources and merge them into one deduplicated list.
#
# Sources (each optional, skipped if the tool is missing):
#   gau, waybackurls, katana (active crawl), plus this repo's alienvault.sh.
#
# Usage:
#   ./urlcollect.sh example.com
#   ./urlcollect.sh -l all_subdomains.txt -o urls_output
#   ./urlcollect.sh -l live.txt --crawl        # include active katana crawl
#   cat live.txt | ./urlcollect.sh -l -

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

OUT_DIR="urls_output"
CRAWL=0
TARGETS=()

usage() {
  cat <<EOF
Usage: $0 [options] <domain> [domain...]
       $0 [options] -l <file>

Options:
  -l, --list <file>   Domains/hosts, one per line ('-' for stdin).
  -o, --output <dir>  Output directory (default: $OUT_DIR)
      --crawl         Also run an active katana crawl (louder, slower).
  -h, --help          Show this help

Output:
  <outdir>/all_urls.txt     merged, deduplicated URLs
  <outdir>/raw/*.txt        per-source raw output
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list)   [ $# -lt 2 ] && die "$1 requires a file argument."
                 while IFS= read -r l; do TARGETS+=("$l"); done < <(read_targets "$2"); shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    --crawl)     CRAWL=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          err "Unknown option: $1"; usage; exit 1 ;;
    *)           while IFS= read -r l; do TARGETS+=("$l"); done < <(normalize_domain "$1"); shift ;;
  esac
done

[ "${#TARGETS[@]}" -eq 0 ] && { err "No targets provided."; usage; exit 1; }

raw="$OUT_DIR/raw"; mkdir -p "$raw"
list="$OUT_DIR/.targets.tmp"; printf '%s\n' "${TARGETS[@]}" | grep -v '^$' | sort -u > "$list"
info "collecting URLs for $(wc -l <"$list" | tr -d ' ') target(s)"

if have gau; then
  info "gau..."
  gau --threads 5 < "$list" 2>/dev/null | sort -u > "$raw/gau.txt" || true
else warn "gau not found — skipping"; fi

if have waybackurls; then
  info "waybackurls..."
  waybackurls < "$list" 2>/dev/null | sort -u > "$raw/waybackurls.txt" || true
else warn "waybackurls not found — skipping"; fi

if [ -f "$SCRIPT_DIR/alienvault.sh" ]; then
  info "alienvault (OTX)..."
  bash "$SCRIPT_DIR/alienvault.sh" -l "$list" -o "$raw/alienvault.txt" >/dev/null 2>&1 || true
fi

if [ "$CRAWL" -eq 1 ]; then
  if have katana; then
    info "katana active crawl..."
    katana -list "$list" -silent -d 3 -jc 2>/dev/null | sort -u > "$raw/katana.txt" || true
  else warn "--crawl requested but katana not found — skipping"; fi
fi

cat "$raw"/*.txt 2>/dev/null | tr -d '\r' | sed '/^$/d' | sort -u > "$OUT_DIR/all_urls.txt"
rm -f "$list"
good "done — $(wc -l <"$OUT_DIR/all_urls.txt" | tr -d ' ') unique URLs -> $OUT_DIR/all_urls.txt"
