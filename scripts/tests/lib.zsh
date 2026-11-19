# Tiny assertion helpers for the script tests. Source this file, call assert_*, then `finish`.
ROOT="${0:A:h:h:h}"
FIXTURES="${0:A:h}/fixtures"
typeset -i FAILED=0 PASSED=0
_fail() { print -u2 -r -- "FAIL: $1"; FAILED+=1 }
_pass() { PASSED+=1 }
assert_eq() { if [[ "$1" == "$2" ]]; then _pass; else _fail "$3 (expected '$1', got '$2')"; fi }
assert_contains() { if [[ "$1" == *"$2"* ]]; then _pass; else _fail "$3 ('$1' lacks '$2')"; fi }
assert_ok() { local m="$1"; shift; if "$@" >/dev/null 2>&1; then _pass; else _fail "$m"; fi }
assert_fails() { local m="$1"; shift; if "$@" >/dev/null 2>&1; then _fail "$m"; else _pass; fi }
finish() { print -r -- "$PASSED passed, $FAILED failed"; (( FAILED == 0 )) }
