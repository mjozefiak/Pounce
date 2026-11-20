#!/bin/zsh
# Which entitlements file and which codesign timestamp argument a signing identity needs.
#
# Whether the identity yields an Apple Team ID decides both, not the identity's name:
#   - entitlements: with a Team ID the embedded frameworks load under library validation, so
#     Resources/Lintel.entitlements has no disable-library-validation; without one (ad-hoc) it is needed and
#     Resources/Lintel-adhoc.entitlements keeps it;
#   - timestamp: a Developer ID signature needs Apple's secure timestamp (notarization requires it); an
#     identity without a Team ID signs with --timestamp=none (no network, works offline).
#
# Source it (scripts/make-app.sh, scripts/make-dmg.sh and the script tests do) to get the functions, or run it:
#   scripts/select-entitlements.sh [--timestamp] < codesign-dv-output
#   scripts/select-entitlements.sh [--timestamp] --identity <identity> [<keychain>]
# The functions take the text of `codesign -dv` (TeamIdentifier=<id> or TeamIdentifier=not set).

_LINTEL_SIGN_ROOT="${${(%):-%x}:A:h:h}"

# Prints the TeamIdentifier value of the given `codesign -dv` text ("not set" included); returns 1 without the line.
_team_identifier_line() {
  local line
  line="$(print -r -- "$1" | grep -E '^TeamIdentifier=.' | head -n 1)" || true
  [[ -n "$line" ]] || return 1
  print -r -- "${line#TeamIdentifier=}"
}

# Prints the entitlements file for the given `codesign -dv` text. Returns 1 when it has no TeamIdentifier line.
select_entitlements() {
  local team
  team="$(_team_identifier_line "$1")" || { echo "select_entitlements: no TeamIdentifier line in the codesign output" >&2; return 1; }
  if [[ "$team" == "not set" ]]; then
    print -r -- "$_LINTEL_SIGN_ROOT/Resources/Lintel-adhoc.entitlements"
  else
    print -r -- "$_LINTEL_SIGN_ROOT/Resources/Lintel.entitlements"
  fi
}

# Prints the codesign timestamp argument for the given `codesign -dv` text.
signing_timestamp_arg() {
  local team
  team="$(_team_identifier_line "$1")" || { echo "signing_timestamp_arg: no TeamIdentifier line in the codesign output" >&2; return 1; }
  if [[ "$team" == "not set" ]]; then
    print -r -- "--timestamp=none"
  else
    print -r -- "--timestamp"
  fi
}

# Signs a copy of /usr/bin/true with the identity (never with a timestamp, so it needs no network) and prints the
# `codesign -dv` output. Arguments: identity [keychain].
probe_signing_identity() {
  local identity="$1" keychain="${2:-}" dir probe
  local -a args
  dir="$(mktemp -d)"
  probe="$dir/probe"
  cp /usr/bin/true "$probe"
  args=(--force --sign "$identity" --timestamp=none)
  [[ -n "$keychain" ]] && args+=(--keychain "$keychain")
  if ! codesign "${args[@]}" "$probe" >/dev/null 2>&1; then
    rm -rf "$dir"
    echo "probe_signing_identity: codesign could not sign a probe binary with the identity" >&2
    return 1
  fi
  codesign -dv "$probe" 2>&1
  rm -rf "$dir"
}

# Run directly (not sourced): the command line front end.
if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file* ]]; then
  set -euo pipefail
  want_timestamp=0
  [[ "${1:-}" == --timestamp ]] && { want_timestamp=1; shift; }
  if [[ "${1:-}" == --identity ]]; then
    [[ -n "${2:-}" ]] || { echo "usage: select-entitlements.sh [--timestamp] --identity <identity> [<keychain>]" >&2; exit 64; }
    dv="$(probe_signing_identity "$2" "${3:-}")"
  else
    dv="$(cat)"
  fi
  if (( want_timestamp )); then signing_timestamp_arg "$dv"; else select_entitlements "$dv"; fi
fi
