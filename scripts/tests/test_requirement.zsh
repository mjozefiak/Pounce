source "${0:A:h}/lib.zsh"
source "$ROOT/scripts/requirement.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
team="$(release_team_id)"
assert_eq "39G44CM6GF" "$team" "the expected Team ID comes from scripts/release-team-id.txt"

good="designated => identifier \"com.lintelapp.Lintel\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = $team"
quoted="${good%= $team}= \"$team\""
adhoc='designated => cdhash H"0123456789abcdef0123456789abcdef01234567"'
selfsigned='designated => identifier "com.lintelapp.Lintel" and certificate leaf = H"0123456789abcdef0123456789abcdef01234567"'
otherteam="${good%$team}ABCDE12345"
print -r -- "$good" > "$tmp/good.txt"
print -r -- "$quoted" > "$tmp/quoted.txt"
print -r -- "$adhoc" > "$tmp/adhoc.txt"
print -r -- "$selfsigned" > "$tmp/selfsigned.txt"
print -r -- "$otherteam" > "$tmp/otherteam.txt"
print -r -- "$good and cdhash H\"00\"" > "$tmp/withcdhash.txt"
print -r -- 'designated => identifier "com.lintelapp.Lintel" and certificate leaf[subject.OU] = 39G44CM6GF' > "$tmp/noanchor.txt"
print -r -- "$good" | sed 's/39G44CM6GF/39G44CM6GFX/' > "$tmp/prefixteam.txt"

req="$ROOT/scripts/requirement.sh"
# check: names the Team ID, anchor apple generic, no cdhash
assert_ok "a Developer ID requirement passes" zsh "$req" check "$tmp/good.txt"
assert_ok "a quoted Team ID passes" zsh "$req" check "$tmp/quoted.txt"
for bad in adhoc selfsigned otherteam withcdhash noanchor prefixteam; do
  assert_fails "$bad is refused" zsh "$req" check "$tmp/$bad.txt"
done
assert_contains "$(zsh "$req" check "$tmp/adhoc.txt" 2>&1)" "cdhash" "ad-hoc is explained"
assert_contains "$(zsh "$req" check "$tmp/otherteam.txt" 2>&1)" "39G44CM6GF" "a wrong team names the expected one"

# compare: placeholder / equal / different
print -r -- 'designated => identifier "com.lintelapp.Lintel" and certificate leaf = H"REPLACE-WITH-THE-LINTEL-RELEASE-CERTIFICATE-SHA1"' > "$tmp/placeholder.txt"
assert_eq "placeholder" "$(requirement_status "$tmp/placeholder.txt" "$tmp/good.txt")" "placeholder detected"
assert_eq "equal" "$(requirement_status "$tmp/good.txt" "$tmp/good.txt")" "same file is equal"
{ print -r -- "$good"; print; } > "$tmp/good-newlines.txt"
assert_eq "equal" "$(requirement_status "$tmp/good.txt" "$tmp/good-newlines.txt")" "whitespace is ignored"
assert_eq "different" "$(requirement_status "$tmp/good.txt" "$tmp/otherteam.txt")" "another team is different"
assert_eq "different" "$(requirement_status "$tmp/good.txt" "$tmp/adhoc.txt")" "ad-hoc is different"
assert_ok "equal passes" zsh "$req" compare "$tmp/good.txt" "$tmp/good-newlines.txt"
assert_fails "different fails" zsh "$req" compare "$tmp/good.txt" "$tmp/otherteam.txt"
assert_fails "placeholder fails by default (tag run)" zsh "$req" compare "$tmp/placeholder.txt" "$tmp/good.txt"
assert_fails "placeholder fails with --on-placeholder fail" zsh "$req" compare "$tmp/placeholder.txt" "$tmp/good.txt" --on-placeholder fail
assert_ok "placeholder only warns with --on-placeholder warn (manual run)" zsh "$req" compare "$tmp/placeholder.txt" "$tmp/good.txt" --on-placeholder warn
assert_contains "$(GITHUB_ACTIONS=true zsh "$req" compare "$tmp/placeholder.txt" "$tmp/good.txt" --on-placeholder warn 2>&1)" "::warning::" "placeholder warning is an annotation"
assert_contains "$(GITHUB_ACTIONS=true zsh "$req" compare "$tmp/placeholder.txt" "$tmp/good.txt" 2>&1)" "::error::" "placeholder error is an annotation"
assert_fails "different fails even with warn" zsh "$req" compare "$tmp/good.txt" "$tmp/otherteam.txt" --on-placeholder warn

# the committed placeholder file is still a placeholder until Step 3.4 (or a real requirement, then this still holds)
case "$(requirement_status "$ROOT/Resources/designated-requirement.txt" "$tmp/good.txt")" in
  placeholder|equal|different) _pass ;;
esac
finish
