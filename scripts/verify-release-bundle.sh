#!/bin/zsh
# Verifies a release bundle: Developer ID signed, notarized and stapled.
#
# Usage: scripts/verify-release-bundle.sh <Lintel.app> [<Lintel.dmg>]
#
# Fails unless, for the app:
#   - codesign --verify --strict --deep passes;
#   - the designated requirement names the Team ID of scripts/release-team-id.txt through certificate
#     leaf[subject.OU] and anchor apple generic, and has no cdhash (a cdhash means ad-hoc);
#   - spctl -a -vvv -t exec reports "accepted" and "source=Notarized Developer ID";
#   - xcrun stapler validate passes;
# and, when a DMG is given:
#   - codesign --verify --strict passes, spctl -a -vvv -t open --context context:primary-signature reports
#     "accepted" and "source=Notarized Developer ID" and xcrun stapler validate passes.
# Every failed check is printed; the exit status is 1 when there is any. It prints the app's designated requirement
# (also to $REQUIREMENT_OUT when set), which Step 3.4 records in Resources/designated-requirement.txt.
set -uo pipefail

ROOT="${0:A:h:h}"
source "$ROOT/scripts/requirement.sh"

APP="${1:-}"
DMG="${2:-}"
if [[ -z "$APP" || $# -gt 2 ]]; then echo "usage: verify-release-bundle.sh <app> [<dmg>]" >&2; exit 64; fi
[[ -d "$APP" ]] || { echo "verify-release-bundle: no such app bundle: $APP" >&2; exit 64; }
[[ -z "$DMG" || -f "$DMG" ]] || { echo "verify-release-bundle: no such file: $DMG" >&2; exit 64; }

TEAM="$(release_team_id)"
typeset -i FAILURES=0
fail() { FAILURES+=1; _req_msg error "$1"; }
step() { print -r -- "-- $1"; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "codesign --verify --strict --deep $APP"
if ! out="$(codesign --verify --strict --deep --verbose=2 "$APP" 2>&1)"; then
  fail "codesign --verify failed for the app: $out"
fi

step "designated requirement"
codesign -dr - "$APP" > "$TMP/requirement.txt" 2>/dev/null || fail "codesign -dr could not read the app's requirement"
cat "$TMP/requirement.txt"
[[ -n "${REQUIREMENT_OUT:-}" ]] && cp "$TMP/requirement.txt" "$REQUIREMENT_OUT"
if ! problems="$(requirement_problems "$TMP/requirement.txt" "$TEAM")"; then
  print -r -- "$problems" | while IFS= read -r line; do echo "  $line"; done
  fail "the app's designated requirement is not a Developer ID requirement for Team ID $TEAM (see above)"
fi

step "spctl -a -vvv -t exec $APP"
out="$(spctl -a -vvv -t exec "$APP" 2>&1)"; print -r -- "$out"
[[ "$out" == *": accepted"* && "$out" == *"source=Notarized Developer ID"* ]] || fail "spctl does not accept the app as 'Notarized Developer ID' (the app is not notarized, or not signed with Developer ID)"

step "xcrun stapler validate $APP"
out="$(xcrun stapler validate "$APP" 2>&1)" || fail "stapler validate failed for the app: the notarization ticket is not stapled"

if [[ -n "$DMG" ]]; then
  step "codesign --verify --strict $DMG"
  out="$(codesign --verify --strict --verbose=2 "$DMG" 2>&1)" || fail "codesign --verify failed for the DMG: $out"
  step "spctl -a -vvv -t open --context context:primary-signature $DMG"
  out="$(spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1)"; print -r -- "$out"
  [[ "$out" == *": accepted"* && "$out" == *"source=Notarized Developer ID"* ]] || fail "spctl does not accept the DMG as 'Notarized Developer ID'"
  step "xcrun stapler validate $DMG"
  out="$(xcrun stapler validate "$DMG" 2>&1)" || fail "stapler validate failed for the DMG: the notarization ticket is not stapled"
fi

if (( FAILURES > 0 )); then
  echo "verify-release-bundle: $FAILURES check(s) failed." >&2
  exit 1
fi
echo "verify-release-bundle: all checks passed (Team ID $TEAM)."
