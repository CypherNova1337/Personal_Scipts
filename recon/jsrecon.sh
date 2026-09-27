#!/usr/bin/env bash
#
# jsrecon.sh — find JavaScript files referenced by target URLs, download them,
# and mine them for endpoints and likely secrets.
#
# Endpoint extraction prefers 'linkfinder' if present, otherwise a built-in
# grep pass. Secret detection is a heuristic grep for common key patterns —
# always verify hits by hand.
#
# Usage:
#   ./jsrecon.sh -i all_urls.txt
#   ./jsrecon.sh -i live.txt -o js_output
#   cat urls.txt | ./jsrecon.sh
#
# Output (in <outdir>, default: js_output):
#   js_urls.txt     discovered .js URLs
#   endpoints.txt   paths/endpoints mined from the JS
#   secrets.txt     lines matching secret-like patterns (review manually!)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

INPUT=""
OUT_DIR="js_output"

usage() {
  cat <<EOF
Usage: $0 [-i <urlfile>] [-o <dir>]
       cat urls.txt | $0

Options:
  -i, --input <file>   URL list (default: stdin)
  -o, --output <dir>   Output directory (default: $OUT_DIR)
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)  INPUT="$2"; shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *)           err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

need curl
mkdir -p "$OUT_DIR" "$OUT_DIR/files"

SRC="$OUT_DIR/.input.tmp"
if [ -n "$INPUT" ]; then [ -f "$INPUT" ] || die "input not found: $INPUT"; tr -d '\r' < "$INPUT" > "$SRC"
else tr -d '\r' > "$SRC"; fi
[ -s "$SRC" ] || { rm -f "$SRC"; die "no input URLs"; }

# 1. Collect .js URLs already present in the input, plus any referenced by
#    the fetched HTML pages.
grep -Eio 'https?://[^ "'\''<>]+\.js([?#][^ "'\''<>]*)?' "$SRC" | sort -u > "$OUT_DIR/js_urls.txt" || true

info "harvesting <script src> from page URLs..."
while IFS= read -r url; do
  case "$url" in *.js|*.js\?*) continue ;; esac
  curl -s --max-time 15 -L "$url" 2>/dev/null \
    | grep -Eio 'src=["'\'']?[^"'\'' >]+\.js' \
    | sed -E 's/^src=["'\'']?//' \
    | while read -r js; do
        case "$js" in
          http*) echo "$js" ;;
          //*)   echo "https:$js" ;;
          /*)    echo "${url%%/*}//$(printf '%s' "$url" | sed -E 's#https?://##; s#/.*##')$js" ;;
        esac
      done
done < "$SRC" >> "$OUT_DIR/js_urls.txt" 2>/dev/null || true
sort -u -o "$OUT_DIR/js_urls.txt" "$OUT_DIR/js_urls.txt"
good "$(wc -l <"$OUT_DIR/js_urls.txt" | tr -d ' ') JS URLs -> $OUT_DIR/js_urls.txt"

# 2. Download each JS file.
info "downloading JS files..."
i=0
while IFS= read -r js; do
  [ -z "$js" ] && continue
  i=$((i+1))
  curl -s --max-time 20 -L "$js" -o "$OUT_DIR/files/$i.js" 2>/dev/null || true
done < "$OUT_DIR/js_urls.txt"

# 3. Extract endpoints.
info "extracting endpoints..."
if have linkfinder; then
  for f in "$OUT_DIR"/files/*.js; do
    [ -f "$f" ] || continue
    linkfinder -i "$f" -o cli 2>/dev/null
  done | sort -u > "$OUT_DIR/endpoints.txt"
else
  warn "linkfinder not found — using built-in grep extractor"
  grep -Ehio '["'\''`](/[a-zA-Z0-9_?&=./~-]+|https?://[a-zA-Z0-9_?&=./~:-]+)["'\''`]' \
    "$OUT_DIR"/files/*.js 2>/dev/null \
    | tr -d '"'\''`' | sort -u > "$OUT_DIR/endpoints.txt" || true
fi
good "$(wc -l <"$OUT_DIR/endpoints.txt" 2>/dev/null | tr -d ' ') endpoints -> $OUT_DIR/endpoints.txt"

# 4. Heuristic secret scan.
info "scanning for secret-like strings (review manually)..."
grep -EHino \
  '(api[_-]?key|secret|token|passwd|password|authorization|bearer|aws_access_key_id|aws_secret_access_key|private_key)["'\'' :=]+[A-Za-z0-9/_+.-]{8,}' \
  "$OUT_DIR"/files/*.js 2>/dev/null | sort -u > "$OUT_DIR/secrets.txt" || true
n=$(wc -l <"$OUT_DIR/secrets.txt" 2>/dev/null | tr -d ' ')
[ "$n" -gt 0 ] && warn "$n potential secret line(s) -> $OUT_DIR/secrets.txt (verify by hand)" || good "no obvious secrets found"

rm -f "$SRC"
