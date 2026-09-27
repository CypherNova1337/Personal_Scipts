#!/usr/bin/env bash
#
# alienvault.sh — pull known URLs for domains from AlienVault OTX.
#
# Queries the OTX "url_list" indicator for each hostname, following
# pagination, and writes the discovered URLs to an output file.
#
# Usage:
#   ./alienvault.sh <domain>
#   ./alienvault.sh -l domains.txt
#   ./alienvault.sh -l domains.txt -o otx_urls.txt
#   cat domains.txt | ./alienvault.sh -l -

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

OUTPUT_FILE="alienvault_urls.txt"
LIMIT=500
DOMAINS=()

usage() {
  cat <<EOF
Usage: $0 [options] <domain> [domain...]
       $0 [options] -l <file>

Options:
  -l, --list <file>   File with one domain per line ('-' for stdin).
  -o, --output <file> Output file (default: $OUTPUT_FILE)
  -h, --help          Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list)   [ $# -lt 2 ] && die "$1 requires a file argument."
                 while IFS= read -r l; do DOMAINS+=("$l"); done < <(read_targets "$2"); shift 2 ;;
    -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          err "Unknown option: $1"; usage; exit 1 ;;
    *)           while IFS= read -r l; do DOMAINS+=("$l"); done < <(normalize_domain "$1"); shift ;;
  esac
done

need curl jq
[ "${#DOMAINS[@]}" -eq 0 ] && { err "No domains provided."; usage; exit 1; }

: > "$OUTPUT_FILE"
info "results -> $OUTPUT_FILE"

for domain in "${DOMAINS[@]}"; do
  [ -z "$domain" ] && continue
  info "fetching URLs for $domain"
  page=1
  while true; do
    response=$(curl -s --max-time 60 \
      "https://otx.alienvault.com/api/v1/indicators/hostname/${domain}/url_list?limit=${LIMIT}&page=${page}")
    urls=$(printf '%s' "$response" | jq -r '.url_list[]?.url // empty' 2>/dev/null)
    [ -z "$urls" ] && break
    printf '%s\n' "$urls" >> "$OUTPUT_FILE"
    count=$(printf '%s' "$response" | jq -r '.url_list | length' 2>/dev/null)
    [ -z "$count" ] && break
    [ "$count" -lt "$LIMIT" ] && break
    page=$((page + 1))
  done
  good "finished $domain"
done

sort -u -o "$OUTPUT_FILE" "$OUTPUT_FILE"
good "done — $(wc -l <"$OUTPUT_FILE" | tr -d ' ') unique URLs in $OUTPUT_FILE"
