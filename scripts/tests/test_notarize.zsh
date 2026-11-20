source "${0:A:h}/lib.zsh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# A stub xcrun: `notarytool submit` prints the JSON in $STUB_RESULT, `notarytool log` writes a file. It records
# whether the key file existed when it was called, so the test can check the temp key is created and then removed.
mkdir "$tmp/bin"
cat > "$tmp/bin/xcrun" <<'STUB'
#!/bin/zsh
[[ "$1" == notarytool ]] || exit 99
shift
sub="$1"; shift
keyfile=""
while (( $# )); do case "$1" in --key) keyfile="$2"; shift 2 ;; *) args+=("$1"); shift ;; esac; done
[[ -f "$keyfile" ]] && print -r -- "$keyfile" >> "$STUB_KEYFILES"
case "$sub" in
  submit) print -r -- "$STUB_RESULT"; exit "${STUB_RC:-0}" ;;
  log) print -r -- '{"issues":[]}' > "${args[-1]}"; exit 0 ;;
esac
STUB
chmod +x "$tmp/bin/xcrun"
print x > "$tmp/file.zip"
export PATH="$tmp/bin:$PATH" STUB_KEYFILES="$tmp/keyfiles"
export NOTARY_KEY_P8="not-a-real-key" NOTARY_KEY_ID="KEYID" NOTARY_ISSUER_ID="ISSUER"
n="$ROOT/scripts/notarize.sh"

STUB_RESULT='{"id":"abc","status":"Accepted"}' assert_ok "an accepted submission passes" zsh "$n" "$tmp/file.zip" "$tmp/logs"
keyfile="$(head -n 1 "$tmp/keyfiles")"
assert_ok "the API key reached notarytool" test -n "$keyfile"
assert_fails "the temporary key file is deleted on exit" test -e "$keyfile"
assert_fails "no log is fetched for an accepted submission" test -d "$tmp/logs"

STUB_RESULT='{"id":"abc","status":"Invalid"}' assert_fails "an invalid submission fails" zsh "$n" "$tmp/file.zip" "$tmp/logs"
assert_ok "the notary log of a failure is saved" test -s "$tmp/logs/file.zip.notary-log.json"
STUB_RESULT='{"id":"abc","status":"Accepted"}' STUB_RC=1 assert_fails "a failing notarytool fails even with an Accepted body" zsh "$n" "$tmp/file.zip" "$tmp/logs2"
STUB_RESULT='garbage' assert_fails "an unreadable answer fails" zsh "$n" "$tmp/file.zip" "$tmp/logs3"
out="$(STUB_RESULT='{"id":"abc","status":"Accepted"}' zsh "$n" "$tmp/file.zip" "$tmp/logs" 2>&1)"
assert_fails "the key never appears in the output" grep -q "not-a-real-key" <<<"$out"
(unset NOTARY_KEY_P8; assert_fails "a missing secret is refused" zsh "$n" "$tmp/file.zip")
assert_fails "a missing file is refused" zsh "$n" "$tmp/nope.zip"
finish
