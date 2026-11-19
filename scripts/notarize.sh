#!/bin/zsh
# Submits a file to Apple's notary service and waits for the verdict.
#
# Usage: scripts/notarize.sh <file.zip|file.dmg|file.pkg> [<log-dir>]
# Environment (the release workflow's Environment secrets; read here, never printed):
#   NOTARY_KEY_P8, NOTARY_KEY_ID, NOTARY_ISSUER_ID   the App Store Connect API key
# The key is written to a temporary file (mode 0600) that is deleted on exit. On a verdict other than Accepted the
# notary log is fetched into <log-dir> (default: ./notary-logs) and the script exits 1.
set -euo pipefail

FILE="${1:-}"
LOG_DIR="${2:-notary-logs}"
[[ -f "$FILE" ]] || { echo "usage: notarize.sh <file> [<log-dir>]" >&2; exit 64; }
for v in NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  [[ -n "${(P)v:-}" ]] || { echo "notarize.sh: $v is not set" >&2; exit 64; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
KEY="$TMP/AuthKey.p8"
(umask 077 && printf '%s' "$NOTARY_KEY_P8" > "$KEY")
AUTH=(--key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")

echo "Submitting ${FILE:t} to the notary service (this waits for the verdict)."
set +e
xcrun notarytool submit "$FILE" "${AUTH[@]}" --wait --output-format json > "$TMP/result.json"
SUBMIT_RC=$?
set -e
ID="$(plutil -extract id raw -o - "$TMP/result.json" 2>/dev/null || true)"
STATUS="$(plutil -extract status raw -o - "$TMP/result.json" 2>/dev/null || true)"
echo "Notarization of ${FILE:t}: submission ${ID:-unknown}, status ${STATUS:-unknown}."
if [[ "$STATUS" == Accepted && $SUBMIT_RC -eq 0 ]]; then
  exit 0
fi
mkdir -p "$LOG_DIR"
if [[ -n "$ID" ]]; then
  xcrun notarytool log "$ID" "${AUTH[@]}" "$LOG_DIR/${FILE:t}.notary-log.json" || echo "Could not fetch the notary log." >&2
fi
echo "notarize.sh: ${FILE:t} was not accepted (status ${STATUS:-unknown}, exit $SUBMIT_RC)." >&2
exit 1
