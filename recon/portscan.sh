#!/usr/bin/env bash
#
# portscan.sh — fast port discovery with naabu, then optional service/version
# fingerprinting with nmap on just the open ports.
#
# Usage:
#   ./portscan.sh -i all_subdomains.txt
#   ./portscan.sh -i hosts.txt -o ports_out --top 1000 --nmap
#   ./portscan.sh -i hosts.txt -p 80,443,8080,8443
#
# Output (in <outdir>, default: ports_output):
#   naabu.txt       host:port lines for every open port
#   nmap/*.txt      per-host nmap -sV output (only with --nmap)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

INPUT=""
OUT_DIR="ports_output"
TOP_PORTS="1000"
PORTS=""
RUN_NMAP=0
RATE=1000

usage() {
  cat <<EOF
Usage: $0 -i <hostfile> [options]

Options:
  -i, --input <file>   Host list (required).
  -o, --output <dir>   Output directory (default: $OUT_DIR)
      --top <n>        naabu top-ports to scan (default: $TOP_PORTS)
  -p, --ports <list>   Explicit ports (e.g. 80,443,8080). Overrides --top.
      --rate <n>       naabu packets/sec (default: $RATE)
      --nmap           Run nmap -sV on discovered open ports.
  -h, --help           Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)  INPUT="$2"; shift 2 ;;
    -o|--output) OUT_DIR="$2"; shift 2 ;;
    --top)       TOP_PORTS="$2"; shift 2 ;;
    -p|--ports)  PORTS="$2"; shift 2 ;;
    --rate)      RATE="$2"; shift 2 ;;
    --nmap)      RUN_NMAP=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

[ -n "$INPUT" ] && [ -f "$INPUT" ] || { err "provide a valid -i <hostfile>"; usage; exit 1; }
need naabu
mkdir -p "$OUT_DIR"

info "scanning ports on $(wc -l <"$INPUT" | tr -d ' ') hosts"
if [ -n "$PORTS" ]; then
  naabu -l "$INPUT" -p "$PORTS" -rate "$RATE" -silent -o "$OUT_DIR/naabu.txt" >/dev/null 2>&1
else
  naabu -l "$INPUT" -top-ports "$TOP_PORTS" -rate "$RATE" -silent -o "$OUT_DIR/naabu.txt" >/dev/null 2>&1
fi
good "open ports: $(wc -l <"$OUT_DIR/naabu.txt" | tr -d ' ')  ->  $OUT_DIR/naabu.txt"

if [ "$RUN_NMAP" -eq 1 ]; then
  need nmap
  mkdir -p "$OUT_DIR/nmap"
  info "running nmap -sV on open ports..."
  # Group open ports by host so each host gets one nmap invocation.
  awk -F: '{ports[$1]=ports[$1]","$2} END{for(h in ports){p=ports[h];sub(/^,/,"",p);print h" "p}}' \
    "$OUT_DIR/naabu.txt" | while read -r host plist; do
      info "  nmap $host ($plist)"
      nmap -sV -Pn -p "$plist" "$host" -oN "$OUT_DIR/nmap/${host}.txt" >/dev/null 2>&1 || \
        warn "nmap failed for $host"
    done
  good "nmap output -> $OUT_DIR/nmap/"
fi
