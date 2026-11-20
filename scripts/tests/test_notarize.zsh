source "${0:A:h}/lib.zsh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# A stub xcrun. `notarytool submit` must not be asked to wait: it prints $STUB_SUBMIT (an upload result). `info` prints a
# status from $STUB_STATUS. `log` writes a file. The key file's existence is recorded on every call, and every call's
# arguments go to $STUB_CALLS so the test can check what was (not) passed.
mkdir "$tmp/bin"
cat > "$tmp/bin/xcrun" <<'STUB'
#!/bin/zsh
[[ "$1" == notarytool ]] || exit 99
shift
sub="$1"; shift
print -r -- "$sub $*" | sed -E 's/--key [^ ]+/--key <file>/' >> "$STUB_CALLS"
keyfile=""
args=()
while (( $# )); do case "$1" in --key) keyfile="$2"; shift 2 ;; *) args+=("$1"); shift ;; esac; done
[[ -f "$keyfile" ]] && print -r -- "$keyfile" >> "$STUB_KEYFILES"
case "$sub" in
  submit) [[ "${STUB_SUBMIT_SLEEP:-0}" == 0 ]] || sleep "$STUB_SUBMIT_SLEEP"; print -r -- "$STUB_SUBMIT"; exit "${STUB_SUBMIT_RC:-0}" ;;
  info) print -r -- "{\"id\":\"abc-123\",\"status\":\"$STUB_STATUS\"}"; exit "${STUB_INFO_RC:-0}" ;;
  log) print -r -- '{"issues":[]}' > "${args[-1]}"; exit 0 ;;
esac
STUB
chmod +x "$tmp/bin/xcrun"
print x > "$tmp/Lintel-app.zip"
export PATH="$tmp/bin:$PATH" STUB_CALLS="$tmp/calls" STUB_KEYFILES="$tmp/keyfiles"
export NOTARY_KEY_P8="SENTINEL-KEY-CONTENT-31337" NOTARY_KEY_ID="SENTINEL-KEYID-4242" NOTARY_ISSUER_ID="SENTINEL-ISSUER-9999"
export NOTARY_POLL_SECONDS=1 NOTARY_PROGRESS_SECONDS=1 NOTARY_WAIT_SECONDS=3 NOTARY_UPLOAD_SECONDS=3
export STUB_SUBMIT='{"id":"abc-123","message":"Successfully uploaded file"}'
n="$ROOT/scripts/notarize.sh"
run() { out="$(zsh "$n" "$tmp/Lintel-app.zip" "$tmp/logs" 2>&1)"; rc=$?; }

# Accepted
: > "$tmp/calls"; rm -rf "$tmp/logs"; rm -f "$tmp/gh-output"
export GITHUB_OUTPUT="$tmp/gh-output"
STUB_STATUS=Accepted run
assert_eq "0" "$rc" "accepted exits 0"
assert_contains "$out" "abc-123" "the submission id is printed"
assert_eq "abc-123" "$(<"$tmp/logs/Lintel-app.zip.submission-id")" "the id is written to the log directory"
assert_contains "$(<"$tmp/gh-output")" "submission-id-Lintel-app_zip=abc-123" "the id is written to GITHUB_OUTPUT"
assert_fails "submit is never asked to wait" grep -q -- "--wait" "$tmp/calls"
assert_ok "submit is asked not to wait" grep -q -- "submit .*--no-wait" "$tmp/calls"
assert_fails "no log is fetched for an accepted submission" test -f "$tmp/logs/Lintel-app.zip.notary-log.json"
keyfile="$(head -n 1 "$tmp/keyfiles")"
assert_ok "the API key reached notarytool" test -n "$keyfile"
assert_fails "the temporary key file is deleted on exit" test -e "$keyfile"
for secret in SENTINEL-KEY-CONTENT-31337; do
  assert_fails "the key content never appears in the output" grep -q "$secret" <<<"$out"
done
assert_fails "the key content never appears in the id file or GITHUB_OUTPUT" grep -rq "SENTINEL-KEY" "$tmp/logs" "$tmp/gh-output"
unset GITHUB_OUTPUT

# Rejected: log fetched, status 1
rm -rf "$tmp/logs"
STUB_STATUS=Invalid run
assert_eq "1" "$rc" "invalid exits 1"
assert_contains "$out" "::error::Apple rejected" "rejection has its own message"
assert_ok "the notary log of a rejection is saved" test -s "$tmp/logs/Lintel-app.zip.notary-log.json"
assert_ok "the id file exists for a rejection too" test -s "$tmp/logs/Lintel-app.zip.submission-id"
STUB_STATUS=Rejected run
assert_eq "1" "$rc" "rejected exits 1"

# Still In Progress at the bound: status 3, the id in the message, no log fetch
rm -rf "$tmp/logs"
STUB_STATUS="In Progress" run
assert_eq "3" "$rc" "in progress at the bound exits 3"
assert_contains "$out" "abc-123" "the timeout message gives the id"
assert_contains "$out" "Apple's queue" "the timeout message says it is Apple's queue"
assert_contains "$out" "new run signs a new binary" "the timeout message says to start again"
assert_contains "$out" "status In Progress" "progress lines are printed while waiting"
assert_fails "no log is fetched at the bound" test -f "$tmp/logs/Lintel-app.zip.notary-log.json"
assert_ok "the id file survives the timeout" test -s "$tmp/logs/Lintel-app.zip.submission-id"

# The upload returns no id / fails / hangs: status 2, nothing waits
rm -rf "$tmp/logs"
STUB_SUBMIT='{"message":"no id here"}' STUB_STATUS=Accepted run
assert_eq "2" "$rc" "an upload without an id exits 2"
assert_contains "$out" "returned no submission id" "the missing id is explained"
STUB_SUBMIT='{"id":"abc-123"}' STUB_SUBMIT_RC=1 STUB_STATUS=Accepted run
assert_eq "2" "$rc" "a failing upload exits 2"
STUB_SUBMIT_SLEEP=30 NOTARY_UPLOAD_SECONDS=2 STUB_STATUS=Accepted run
assert_eq "2" "$rc" "an upload that hangs exits 2 at its bound"
assert_contains "$out" "did not finish within 2 s" "the upload timeout is explained"

# Status reads that keep failing give a plain error, not a verdict
STUB_STATUS=Accepted STUB_INFO_RC=1 NOTARY_POLL_SECONDS=0 run
assert_eq "1" "$rc" "unreadable status exits 1"
assert_contains "$out" "Could not read the status" "unreadable status is explained"

# No secret value anywhere in any output
for case_status in Accepted Invalid "In Progress"; do
  STUB_STATUS="$case_status" run
  for secret in SENTINEL-KEY-CONTENT-31337 SENTINEL-KEYID-4242 SENTINEL-ISSUER-9999; do
    assert_fails "$secret does not appear ($case_status)" grep -q "$secret" <<<"$out"
  done
done

# NOTARY_WAIT_MINUTES: validated before anything is uploaded
: > "$tmp/calls"
for bad in abc 0 -5 1.5 "" " 5" 241 1000 007 "5m"; do
  [[ -z "$bad" ]] && continue
  NOTARY_WAIT_MINUTES="$bad" STUB_STATUS=Accepted run
  assert_eq "64" "$rc" "NOTARY_WAIT_MINUTES='$bad' is refused"
  assert_contains "$out" "from 1 to 240" "the refusal of '$bad' states the range"
done
assert_fails "nothing was submitted for a refused bound" grep -q submit "$tmp/calls"
unset NOTARY_WAIT_SECONDS
NOTARY_WAIT_MINUTES=240 STUB_STATUS=Accepted run
assert_eq "0" "$rc" "the upper limit itself is accepted"
NOTARY_WAIT_MINUTES="" STUB_STATUS=Accepted run
assert_eq "0" "$rc" "an empty value means the default"
NOTARY_WAIT_MINUTES=1 STUB_STATUS="In Progress" NOTARY_POLL_SECONDS=1 NOTARY_UPLOAD_SECONDS=3 NOTARY_WAIT_SECONDS=2 run
assert_eq "3" "$rc" "NOTARY_WAIT_SECONDS wins over NOTARY_WAIT_MINUTES"
assert_contains "$out" "after 2 s" "the bound in seconds is the one reported"

(unset NOTARY_KEY_P8; assert_fails "a missing secret is refused" zsh "$n" "$tmp/Lintel-app.zip")
assert_fails "a missing file is refused" zsh "$n" "$tmp/nope.zip"
finish
