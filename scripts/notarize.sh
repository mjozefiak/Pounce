#!/bin/zsh
# Submits a file to Apple's notary service and waits, with a bound, for the verdict.
#
# Usage: scripts/notarize.sh <file.zip|file.dmg|file.pkg> [<log-dir>]
# Environment (the release workflow's Environment secrets; read here, never printed):
#   NOTARY_KEY_P8, NOTARY_KEY_ID, NOTARY_ISSUER_ID   the App Store Connect API key
# Optional bounds, in seconds (defaults chosen so that the app and the DMG fit in the sign job):
#   NOTARY_UPLOAD_SECONDS    longest upload (default 600)
#   NOTARY_WAIT_MINUTES      longest wait for the verdict after the upload, whole minutes 1..240 (default 40). The
#                            release workflow sets it from the manual run's `notary_wait_minutes` input; empty = default.
#   NOTARY_WAIT_SECONDS      the same in seconds, no upper limit; wins over NOTARY_WAIT_MINUTES (the script tests use it)
#   NOTARY_POLL_SECONDS      pause between status requests (default 30)
#   NOTARY_PROGRESS_SECONDS  pause between progress lines (default 60)
#
# 1. The file is submitted WITHOUT waiting (`notarytool submit --no-wait`), so the submission id is known as soon as the
#    upload ends. It is printed at once (it is not a secret), written to $GITHUB_OUTPUT (key
#    submission-id-<file name>) and to <log-dir>/<file name>.submission-id, so a cancelled job still shows it.
# 2. The verdict is polled with `notarytool info <id>` until the bound; a progress line is printed every minute.
# The API key is written to a temporary file (mode 0600) that is deleted on exit.
#
# Exit status:
#   0  Accepted
#   1  rejected (Invalid or Rejected); the notary log is fetched into <log-dir>; or another error
#   2  the upload failed, timed out or returned no submission id
#   3  still In Progress at the bound: Apple's queue, not our build (the submission id is printed)
#  64  usage, or an invalid bound
set -euo pipefail

FILE="${1:-}"
LOG_DIR="${2:-notary-logs}"
[[ -f "$FILE" ]] || { echo "usage: notarize.sh <file> [<log-dir>]" >&2; exit 64; }
for v in NOTARY_KEY_P8 NOTARY_KEY_ID NOTARY_ISSUER_ID; do
  [[ -n "${(P)v:-}" ]] || { echo "notarize.sh: $v is not set" >&2; exit 64; }
done
UPLOAD_SECONDS="${NOTARY_UPLOAD_SECONDS:-600}"
MAX_WAIT_MINUTES=240
WAIT_MINUTES="${NOTARY_WAIT_MINUTES:-40}"
if [[ ! "$WAIT_MINUTES" =~ '^[1-9][0-9]*$' ]] || (( WAIT_MINUTES > MAX_WAIT_MINUTES )); then
  echo "::error::NOTARY_WAIT_MINUTES must be a whole number of minutes from 1 to ${MAX_WAIT_MINUTES}, not '${WAIT_MINUTES}'." >&2
  exit 64
fi
WAIT_SECONDS="${NOTARY_WAIT_SECONDS:-$(( WAIT_MINUTES * 60 ))}"
POLL_SECONDS="${NOTARY_POLL_SECONDS:-30}"
PROGRESS_SECONDS="${NOTARY_PROGRESS_SECONDS:-60}"
NAME="${FILE:t}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
KEY="$TMP/AuthKey.p8"
(umask 077 && printf '%s' "$NOTARY_KEY_P8" > "$KEY")
AUTH=(--key "$KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
mkdir -p "$LOG_DIR"

json_field() { plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

# 1. Upload, without waiting, under a bound.
echo "Uploading $NAME to the notary service (bound: ${UPLOAD_SECONDS} s)."
xcrun notarytool submit "$FILE" "${AUTH[@]}" --no-wait --output-format json > "$TMP/submit.json" 2> "$TMP/submit.err" &
UPLOAD_PID=$!
SECONDS=0
while kill -0 "$UPLOAD_PID" 2>/dev/null; do
  if (( SECONDS >= UPLOAD_SECONDS )); then
    kill "$UPLOAD_PID" 2>/dev/null || true
    wait "$UPLOAD_PID" 2>/dev/null || true
    echo "::error::The upload of $NAME to the notary service did not finish within ${UPLOAD_SECONDS} s. This is the network or Apple's upload endpoint, not the build. Start the run again." >&2
    exit 2
  fi
  sleep 1
done
set +e; wait "$UPLOAD_PID"; UPLOAD_RC=$?; set -e
ID="$(json_field "$TMP/submit.json" id)"
if [[ $UPLOAD_RC -ne 0 || -z "$ID" ]]; then
  echo "::error::The upload of $NAME to the notary service failed or returned no submission id (exit $UPLOAD_RC). Nothing was submitted; start the run again." >&2
  exit 2
fi
echo "Notary submission id for $NAME: $ID"
print -r -- "$ID" > "$LOG_DIR/$NAME.submission-id"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  print -r -- "submission-id-${NAME//[^A-Za-z0-9_-]/_}=$ID" >> "$GITHUB_OUTPUT"
fi

# 2. Wait for the verdict, with a bound.
STATUS="In Progress"
SECONDS=0
NEXT_PROGRESS=0
FAILED_READS=0
while true; do
  set +e
  xcrun notarytool info "$ID" "${AUTH[@]}" --output-format json > "$TMP/info.json" 2>/dev/null
  INFO_RC=$?
  set -e
  S="$(json_field "$TMP/info.json" status)"
  if [[ $INFO_RC -eq 0 && -n "$S" ]]; then
    STATUS="$S"
    FAILED_READS=0
  else
    FAILED_READS+=1
    if (( FAILED_READS >= 10 )); then
      echo "::error::Could not read the status of notary submission $ID ten times in a row (network or credentials). The submission may still complete at Apple." >&2
      exit 1
    fi
  fi
  [[ "$STATUS" == "In Progress" ]] || break
  if (( SECONDS >= WAIT_SECONDS )); then
    echo "::error::Notarization of $NAME is still In Progress after ${WAIT_SECONDS} s. This is Apple's queue (common for an account's first submissions), not our build. Submission id: $ID. Start the release run again later: a new run signs a new binary, so this submission cannot be reused." >&2
    exit 3
  fi
  if (( SECONDS >= NEXT_PROGRESS )); then
    echo "Notarization of $NAME: status $STATUS, ${SECONDS} s of ${WAIT_SECONDS} s waited (submission $ID)."
    NEXT_PROGRESS=$(( SECONDS + PROGRESS_SECONDS ))
  fi
  sleep "$POLL_SECONDS"
done

echo "Notarization of $NAME: submission $ID, status $STATUS."
if [[ "$STATUS" == Accepted ]]; then
  exit 0
fi
if xcrun notarytool log "$ID" "${AUTH[@]}" "$LOG_DIR/$NAME.notary-log.json" 2>/dev/null; then
  echo "The notary log is in $LOG_DIR/$NAME.notary-log.json."
else
  echo "Could not fetch the notary log." >&2
fi
echo "::error::Apple rejected $NAME (status $STATUS, submission $ID). The notary log is uploaded as an artifact; this is a problem with the build, not a wait." >&2
exit 1
