#!/usr/bin/env bash
#
# subenum.sh — subdomain aggregator.
#
# Runs many passive/active sources concurrently and consolidates the results
# per-target and across all targets. Missing tools are skipped, never fatal.
#
# Sources: subfinder, assetfinder, amass (passive+active), chaos, crt.sh,
#          Wayback Machine, VirusTotal.
#
# Usage:
#   ./subenum.sh example.com
#   ./subenum.sh example.com target.io another.net
#   ./subenum.sh -l domains.txt
#   ./subenum.sh -l domains.txt -o engagement_x -c 4
#   cat domains.txt | ./subenum.sh -l -
#
# API keys (never hardcoded):
#   export VT_API_KEY="..."             # VirusTotal; or put it in ~/.config/recon.env
#
# Output:
#   <outdir>/<domain>/subdomains.txt    per-target results
#   <outdir>/<domain>/raw/*.txt         per-source raw output
#   <outdir>/all_subdomains.txt         deduplicated across all targets

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

# --- Configuration ---------------------------------------------------------

VT_API_KEY="${VT_API_KEY:-}"
[ -f "$HOME/.config/recon.env" ] && . "$HOME/.config/recon.env"

OUT_DIR="recon_output"
CONCURRENCY=3
AMASS_ACTIVE=1
DOMAINS=()

usage() {
  cat <<EOF
Usage: $0 [options] <domain> [domain...]
       $0 [options] -l <file>

Options:
  -l, --list <file>     File with one domain per line ('-' for stdin).
  -o, --output <dir>    Output directory (default: $OUT_DIR)
  -c, --concurrency <n> Domains processed in parallel (default: $CONCURRENCY)
  -p, --passive-only    Skip active Amass enumeration
  -h, --help            Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list)
      [ $# -lt 2 ] && die "$1 requires a file argument."
      while IFS= read -r line; do DOMAINS+=("$line"); done < <(read_targets "$2")
      shift 2 ;;
    -o|--output)       OUT_DIR="$2"; shift 2 ;;
    -c|--concurrency)  CONCURRENCY="$2"; shift 2 ;;
    -p|--passive-only) AMASS_ACTIVE=0; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                err "Unknown option: $1"; usage; exit 1 ;;
    *)                 while IFS= read -r line; do DOMAINS+=("$line"); done < <(normalize_domain "$1"); shift ;;
  esac
done

# Deduplicate while preserving order.
declare -A SEEN=(); CLEANED=()
for d in "${DOMAINS[@]:-}"; do
  [ -z "$d" ] && continue
  [ -n "${SEEN[$d]:-}" ] && continue
  SEEN["$d"]=1; CLEANED+=("$d")
done
DOMAINS=("${CLEANED[@]:-}")

[ "${#DOMAINS[@]}" -eq 0 ] && { err "No domains provided."; usage; exit 1; }
case "$CONCURRENCY" in ''|*[!0-9]*|0) die "Concurrency must be a positive integer." ;; esac

# --- Per-domain enumeration ------------------------------------------------

enumerate_domain() {
  local domain="$1"
  local dir="$OUT_DIR/$domain" raw="$OUT_DIR/$domain/raw"
  mkdir -p "$raw"
  info "enumerating $domain"

  have subfinder   && subfinder -d "$domain" -all -silent            >"$raw/subfinder.txt"   2>/dev/null &
  have assetfinder && assetfinder --subs-only "$domain"              >"$raw/assetfinder.txt" 2>/dev/null &
  have amass       && amass enum -passive -d "$domain"               >"$raw/amass_passive.txt" 2>/dev/null &
  have chaos       && chaos -d "$domain" -silent                     >"$raw/chaos.txt"       2>/dev/null &
  [ "$AMASS_ACTIVE" -eq 1 ] && have amass && \
    amass enum -active -d "$domain"                                  >"$raw/amass_active.txt" 2>/dev/null &

  if have curl && have jq; then
    curl -s --max-time 120 "https://crt.sh/?q=%25.$domain&output=json" \
      | jq -r '.[]?.name_value // empty' 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' | sed 's/\*\.//g' | sort -u >"$raw/crtsh.txt" &
  fi

  if have curl; then
    curl -s --max-time 180 \
      "http://web.archive.org/cdx/search/cdx?url=*.$domain/*&output=text&fl=original&collapse=urlkey" \
      | sed -e 's_https*://__' -e 's_/.*__' -e 's/:.*//' -e 's/^www\.//' \
      | tr '[:upper:]' '[:lower:]' | sort -u >"$raw/wayback.txt" &
  fi

  if [ -n "$VT_API_KEY" ] && have curl && have jq; then
    curl -s --max-time 120 \
      "https://www.virustotal.com/vtapi/v2/domain/report?apikey=$VT_API_KEY&domain=$domain" \
      | jq -r '.subdomains[]? // empty' 2>/dev/null \
      | tr '[:upper:]' '[:lower:]' | sort -u >"$raw/virustotal.txt" &
  fi

  wait

  local re; re="$(domain_regex "$domain")"
  cat "$raw"/*.txt 2>/dev/null \
    | tr -d '\r' | tr '[:upper:]' '[:lower:]' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | grep -E "$re" | grep -Ev '[[:space:]]' \
    | sort -u >"$dir/subdomains.txt"

  good "$domain — $(wc -l <"$dir/subdomains.txt" | tr -d ' ') unique subdomains"
}

# --- Main ------------------------------------------------------------------

mkdir -p "$OUT_DIR"
info "targets: ${#DOMAINS[@]}  output: $OUT_DIR  concurrency: $CONCURRENCY"
[ -z "$VT_API_KEY" ] && warn "VT_API_KEY unset — skipping VirusTotal"

for t in subfinder assetfinder amass chaos curl jq; do
  have "$t" || warn "'$t' not found — that source will be skipped."
done

# Prefer a proper job-slot pool with 'wait -n' when the shell supports it.
if { [ "${BASH_VERSINFO[0]}" -gt 4 ]; } || \
   { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }; then
  USE_WAIT_N=1
else
  USE_WAIT_N=0
fi

running=0
for domain in "${DOMAINS[@]}"; do
  enumerate_domain "$domain" &
  running=$((running + 1))
  if [ "$running" -ge "$CONCURRENCY" ]; then
    if [ "$USE_WAIT_N" -eq 1 ]; then wait -n; running=$((running - 1)); else wait; running=0; fi
  fi
done
wait

info "building combined list..."
cat "$OUT_DIR"/*/subdomains.txt 2>/dev/null | sort -u >"$OUT_DIR/all_subdomains.txt"
good "done — $(wc -l <"$OUT_DIR/all_subdomains.txt" | tr -d ' ') unique subdomains across ${#DOMAINS[@]} target(s)"
info "combined: $OUT_DIR/all_subdomains.txt"
