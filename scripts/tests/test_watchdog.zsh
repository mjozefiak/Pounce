source "${0:A:h}/lib.zsh"
wd="$ROOT/scripts/test-with-watchdog.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export RUNNER_TEMP="$tmp/runner"
mkdir -p "$RUNNER_TEMP"
dir="$RUNNER_TEMP/test-watchdog"

# exit codes are passed through, output reaches stdout
out="$("$wd" --limit 30 --name ok -- sh -c 'echo hello; exit 0')"; rc=$?
assert_eq 0 $rc "exit 0 is passed on"
assert_eq "hello" "$out" "output is passed on"
"$wd" --limit 30 --name bad -- sh -c 'exit 7' >/dev/null; assert_eq 7 $? "non-zero exit is passed on"
"$wd" --limit 30 -- sh -c 'kill -9 $$' >/dev/null 2>&1; (( $? != 0 )) && _pass || _fail "a command killed by a signal fails"
assert_eq "0" "$(ls "$dir" 2>/dev/null | grep -c output)" "no copy of the output is left behind"

# usage errors
assert_fails "unknown option" "$wd" --bogus -- true
assert_fails "bad limit" "$wd" --limit abc -- true
assert_fails "no command" "$wd" --limit 5
assert_fails "--limit without a value" "$wd" --limit
assert_fails "--name without a value" "$wd" --limit 5 --name

# a fast command does not wait for the limit
start=$SECONDS; "$wd" --limit 60 -- true; (( SECONDS - start < 10 )) && _pass || _fail "a quick command returns at once"

# hang: a fake swiftpm-testing-helper that prints Swift Testing lines and never ends
cp /bin/sleep "$tmp/swiftpm-testing-helper"
codesign -s - -f "$tmp/swiftpm-testing-helper" >/dev/null 2>&1
export GITHUB_OUTPUT="$tmp/gh_output"; : >"$GITHUB_OUTPUT"
cat >"$tmp/hang.sh" <<'SH'
print -r -- '◇ Test finishedTest() started.'
print -r -- '◇ Test parameterizedTest(x:) started.'
print -r -- '◇ Test case passing 1 argument x → "secret-value" to parameterizedTest(x:) started.'
print -r -- '✘ Test recordedIssueTest() recorded an issue at File.swift:1:1: Expectation failed: secret-issue'
print -r -- '◇ Test recordedIssueTest() started.'
print -r -- '✔ Test finishedTest() passed after 0.001 seconds.'
print -r -- '◇ Test hungTest() started.'
print -r -- "Test Case '-[Suite stuck]' started."
"$1" 999 &
"$1" 998
SH
start=$SECONDS
out="$("$wd" --limit 4 --name hang -- zsh "$tmp/hang.sh" "$tmp/swiftpm-testing-helper" 2>/dev/null)"; rc=$?
elapsed=$((SECONDS - start))
assert_eq 124 $rc "hang exits 124"
(( elapsed >= 4 && elapsed < 30 )) && _pass || _fail "the limit is in seconds (took ${elapsed}s for 4)"
assert_contains "$out" "::error::hang exceeded 4 s; samples in $dir" "error annotation"
assert_eq "watchdog-dir=$dir" "${out##*$'\n'}" "last stdout line is watchdog-dir"
assert_eq "dir=$dir" "$(<"$GITHUB_OUTPUT")" "dir written to GITHUB_OUTPUT"
assert_ok "unfinished test list exists" test -f "$dir/hang-unfinished-tests.txt"
list="$(<"$dir/hang-unfinished-tests.txt")"
assert_contains "$list" "hungTest()" "hung test is listed"
assert_contains "$list" "-[Suite stuck]" "XCTest case is listed"
assert_contains "$list" "parameterizedTest(x:)" "parameterized test is listed by name"
assert_contains "$list" "recordedIssueTest()" "a test that recorded an issue but did not finish is listed"
[[ "$list" != *secret* ]] && _pass || _fail "no argument values or issue text in the list"
[[ "$list" != *finishedTest* || "$list" == *hungTest* && "${list//hungTest()/}" != *finishedTest* ]] && _pass || _fail "finished test is not listed"
if (( $(ls "$dir"/hang-*-sample.txt 2>/dev/null | wc -l) >= 1 )); then _pass; else _fail "a sample file was written for the helper"; fi
assert_eq "0" "$(ls "$dir" | grep -c output)" "no copy of the output is left behind after a hang"
assert_eq "0" "$(grep -rl 'secret' "$dir" 2>/dev/null | wc -l | tr -d ' ')" "nothing from the output is in the watchdog directory"
sleep 1
assert_eq "" "$(pgrep -f "$tmp/swiftpm-testing-helper" || true)" "no orphans after the kill"

# a process that ignores TERM is killed with KILL
start=$SECONDS
"$wd" --limit 2 --name stubborn -- sh -c 'trap "" TERM; while :; do sleep 1; done' >/dev/null 2>&1; rc=$?
assert_eq 124 $rc "stubborn process still ends with 124"
(( SECONDS - start < 20 )) && _pass || _fail "KILL follows TERM after a few seconds"
sleep 1
assert_eq "" "$(pgrep -f 'trap "" TERM' || true)" "no orphans of the stubborn process"
# regression: a block-buffering writer (perl without autoflush) must still show its lines under the pty
cat >"$tmp/buffered.pl" <<'PL'
print "Test bufferedHang() started.\n";
sleep 600;
PL
rm -f "$dir"/buf-*
"$wd" --limit 3 --name buf -- perl "$tmp/buffered.pl" >/dev/null 2>&1; rc=$?
assert_eq 124 $rc "buffered writer hang exits 124"
assert_contains "$(<"$dir/buf-unfinished-tests.txt")" "bufferedHang()" "list is not empty for a block-buffering writer"

finish
