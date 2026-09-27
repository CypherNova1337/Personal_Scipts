#!/usr/bin/env bash
#
# wayback.sh — pull archived URLs for a domain from the Wayback Machine.
#
# Writes every known URL, and separately the subset whose path ends in an
# "interesting" extension (configs, backups, dumps, keys, docs, archives).
#
# Usage:
#   ./wayback.sh <domain>
#   ./wayback.sh -l domains.txt -o out_dir
#   cat domains.txt | ./wayback.sh -l -

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

OUT_DIR="wayback_output"
DOMAINS=()

# Extensions worth a second look, as a Wayback CDX regex filter fragment.
EXT_RE='(xls|xlsx|xml|json|pdf|sql|doc|docx|pptx|txt|zip|tar\.gz|tgz|bak|7z|rar|log|cache|db|backup|yml|yaml|gz|conf|config|csv|md5|ini|env|apk|crt|pem|key|pub|asc|old|swp)'

usage() {
  cat <<EOF
Usage: $0 [options] <domain> [domain...]
       $0 [options] -l <file>

Options:
  -l, --list <file>   File with one domain per line ('-' for stdin).
  -o, --output <dir>  Output directory (default: $OUT_DIR)
  -h, --help          Show this help

Per domain it writes:
  <outdir>/<domain>/all_urls.txt         every archived URL
  <outdir>/<domain>/interesting.txt      URLs with sensitive-looking extensions
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list)   [ $# -lt 2 ] && die "$1 requires a file argument."
                 while IFS= read -r l; do DOMAINS+=("$l"); done < <(read_targets "$2"); shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    -*)          err "Unknown option: $1"; usage; exit 1 ;;
    *)           while IFS= read -r l; do DOMAINS+=("$l"); done < <(normalize_domain "$1"); shift ;;
  esac
done

need curl
[ "${#DOMAINS[@]}" -eq 0 ] && { err "No domains provided."; usage; exit 1; }

for domain in "${DOMAINS[@]}"; do
  [ -z "$domain" ] && continue
  dir="$OUT_DIR/$domain"; mkdir -p "$dir"
  info "fetching Wayback URLs for $domain"

  curl -s --max-time 180 -G "https://web.archive.org/cdx/search/cdx" \
    --data-urlencode "url=*.$domain/*" \
    --data-urlencode "collapse=urlkey" \
    --data-urlencode "output=text" \
    --data-urlencode "fl=original" \
    | sort -u > "$dir/all_urls.txt"

  curl -s --max-time 180 -G "https://web.archive.org/cdx/search/cdx" \
    --data-urlencode "url=*.$domain/*" \
    --data-urlencode "collapse=urlkey" \
    --data-urlencode "output=text" \
    --data-urlencode "fl=original" \
    --data-urlencode "filter=original:.*\.${EXT_RE}$" \
    | sort -u > "$dir/interesting.txt"

  good "$domain — $(wc -l <"$dir/all_urls.txt" | tr -d ' ') URLs, $(wc -l <"$dir/interesting.txt" | tr -d ' ') interesting"
done
