#!/usr/bin/env bash
#
# probe.sh — turn a list of hosts/subdomains into live HTTP(S) services.
#
# Wraps httpx (projectdiscovery) with sensible defaults and records useful
# metadata (status, title, tech, content-length). Falls back to httprobe for
# a plain live/not-live check if httpx is unavailable.
#
# Usage:
#   ./probe.sh -i all_subdomains.txt
#   ./probe.sh -i all_subdomains.txt -o live/
#   cat all_subdomains.txt | ./probe.sh
#
# Output (in <outdir>, default: probe_output):
#   live.txt        live URLs, one per line (feed this to other tools)
#   httpx.txt       full httpx table with status/title/tech (if httpx present)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

INPUT=""
OUT_DIR="probe_output"
THREADS=50

usage() {
  cat <<EOF
Usage: $0 [-i <file>] [-o <dir>] [-t <threads>]
       cat hosts.txt | $0

Options:
  -i, --input <file>    Host list (default: stdin)
  -o, --output <dir>    Output directory (default: $OUT_DIR)
  -t, --threads <n>     Concurrency (default: $THREADS)
  -h, --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)   INPUT="$2"; shift 2 ;;
    -o|--output)  OUT_DIR="$2"; shift 2 ;;
    -t|--threads) THREADS="$2"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *)            err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
SRC="$OUT_DIR/.input.tmp"
if [ -n "$INPUT" ]; then
  [ -f "$INPUT" ] || die "input file not found: $INPUT"
  tr -d '\r' < "$INPUT" | sort -u > "$SRC"
else
  tr -d '\r' | sort -u > "$SRC"
fi
[ -s "$SRC" ] || { rm -f "$SRC"; die "no input hosts provided"; }

info "probing $(wc -l <"$SRC" | tr -d ' ') hosts"

if have httpx; then
  httpx -l "$SRC" -silent -threads "$THREADS" \
    -status-code -title -tech-detect -content-length -no-color \
    -o "$OUT_DIR/httpx.txt" >/dev/null 2>&1
  awk '{print $1}' "$OUT_DIR/httpx.txt" | sort -u > "$OUT_DIR/live.txt"
elif have httprobe; then
  warn "httpx not found — falling back to httprobe (no metadata)"
  httprobe -c "$THREADS" < "$SRC" | sort -u > "$OUT_DIR/live.txt"
else
  rm -f "$SRC"
  die "need httpx or httprobe on PATH"
fi

rm -f "$SRC"
good "live services: $(wc -l <"$OUT_DIR/live.txt" | tr -d ' ')  ->  $OUT_DIR/live.txt"
