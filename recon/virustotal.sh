#!/usr/bin/env bash
#
# virustotal.sh — pull undetected URLs (and, for IPs, resolved hostnames)
# from the VirusTotal v2 API for domains or IP addresses.
#
# API keys are read from the environment, never hardcoded. Provide one or
# more (comma-separated) to rotate across the public-API rate limit:
#
#   export VT_API_KEYS="key1,key2,key3"     # rotated every 4 requests
#   export VT_API_KEY="key1"                # single key (also honored)
#   # or place either in ~/.config/recon.env
#
# Usage:
#   ./virustotal.sh example.com
#   ./virustotal.sh 8.8.8.8
#   ./virustotal.sh targets.txt        # file of mixed domains/IPs

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/../lib/common.sh"

[ -f "$HOME/.config/recon.env" ] && . "$HOME/.config/recon.env"

need curl jq

# Assemble the key list from VT_API_KEYS (comma-separated) or VT_API_KEY.
IFS=',' read -r -a VT_KEYS <<< "${VT_API_KEYS:-${VT_API_KEY:-}}"
[ "${#VT_KEYS[@]}" -eq 0 ] || [ -z "${VT_KEYS[0]}" ] && \
  die "Set VT_API_KEYS or VT_API_KEY (env or ~/.config/recon.env) before running."

[ $# -ge 1 ] || die "Usage: $0 <ip|domain|file>"

KEY_IDX=0; REQ_COUNT=0
current_key() { printf '%s' "${VT_KEYS[$KEY_IDX]}"; }
rotate_key() {
  REQ_COUNT=$((REQ_COUNT + 1))
  if [ "$REQ_COUNT" -ge 4 ]; then
    REQ_COUNT=0
    KEY_IDX=$(( (KEY_IDX + 1) % ${#VT_KEYS[@]} ))
  fi
}

is_ip() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

fetch() {
  local input; input="$(printf '%s' "$1" | sed 's|https\?://||; s|/.*||')"
  [ -z "$input" ] && return
  local key; key="$(current_key)" url

  if is_ip "$input"; then
    url="https://www.virustotal.com/vtapi/v2/ip-address/report?apikey=$key&ip=$input"
    info "IP: $input"
  else
    url="https://www.virustotal.com/vtapi/v2/domain/report?apikey=$key&domain=$input"
    info "domain: $input"
  fi

  local resp; resp="$(curl -s --max-time 60 "$url")"
  if [ -z "$resp" ]; then err "no response for $input"; rotate_key; return; fi

  if is_ip "$input"; then
    local hosts; hosts="$(printf '%s' "$resp" | jq -r '.resolutions[]?.hostname // empty' 2>/dev/null | sort -u)"
    [ -n "$hosts" ] && { good "resolved hostnames:"; printf '%s\n' "$hosts"; }
  fi

  local urls; urls="$(printf '%s' "$resp" | jq -r '.undetected_urls[]?[0] // empty' 2>/dev/null | sort -u)"
  if [ -n "$urls" ]; then good "undetected URLs:"; printf '%s\n' "$urls"; else warn "no undetected URLs for $input"; fi

  rotate_key
}

if [ -f "$1" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    fetch "$line"
    sleep 15   # public API: ~4 req/min
  done < "$1"
else
  fetch "$1"
fi

good "all done"
