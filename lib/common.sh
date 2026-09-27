#!/usr/bin/env bash
#
# common.sh — shared helpers for the recon/exploit scripts in this repo.
#
# Source it from any bash script:
#     SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#     . "$SCRIPT_DIR/../lib/common.sh"
#
# It provides colored logging, dependency checks, domain normalization,
# and a couple of small utilities so the individual tools stay focused.

# Guard against double-sourcing.
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

# --- Colors (disabled automatically when output is not a TTY) --------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[1;31m'; C_GRN=$'\e[1;32m'
  C_YEL=$'\e[1;33m'; C_BLU=$'\e[1;34m'; C_CYN=$'\e[1;36m'; C_DIM=$'\e[2m'
else
  C_RESET=; C_RED=; C_GRN=; C_YEL=; C_BLU=; C_CYN=; C_DIM=
fi

info()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_RESET" "$*"; }
good()  { printf '%s[+]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YEL" "$C_RESET" "$*" >&2; }
err()   { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { err "$*"; exit 1; }

# --- Dependency handling ---------------------------------------------------

# have <cmd> — true if the command exists on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# need <cmd> [<cmd> ...] — die unless every listed command is present.
need() {
  local missing=() c
  for c in "$@"; do have "$c" || missing+=("$c"); done
  [ "${#missing[@]}" -eq 0 ] || die "missing required tool(s): ${missing[*]}"
}

# --- Domain / URL helpers --------------------------------------------------

# normalize_domain <string> — strip scheme, path, port, whitespace, trailing
# dot; lowercase. Prints nothing for comments/blank input.
normalize_domain() {
  local d="${1%$'\r'}"
  d="${d%%#*}"
  d="$(printf '%s' "$d" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  d="${d#http://}"; d="${d#https://}"
  d="${d%%/*}"; d="${d##*@}"; d="${d%%:*}"; d="${d%.}"
  [ -n "$d" ] && printf '%s\n' "$d"
}

# Anchored regex matching a domain and its subdomains, so a search for
# example.com does not also match evil-example.com.
domain_regex() {
  local esc="${1//./\\.}"
  printf '(^|\\.)%s$' "$esc"
}

# read_targets <arg> — emit normalized domains from either a file path
# (one per line, '-' for stdin) or a single domain argument.
read_targets() {
  local src="$1"
  if [ "$src" = "-" ]; then
    while IFS= read -r line; do normalize_domain "$line"; done
  elif [ -f "$src" ]; then
    while IFS= read -r line; do normalize_domain "$line"; done < "$src"
  else
    normalize_domain "$src"
  fi
}

# timestamp — compact, filename-safe.
timestamp() { date +%Y%m%d-%H%M%S; }
