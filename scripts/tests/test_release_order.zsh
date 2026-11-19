source "${0:A:h}/lib.zsh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
chk="$ROOT/scripts/check-release-order.sh"
git init -q -b main "$tmp/r" && cd "$tmp/r"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git commit -q --allow-empty -m c1; c1="$(git rev-parse HEAD)"
git commit -q --allow-empty -m c2; c2="$(git rev-parse HEAD)"
git commit -q --allow-empty -m c3; c3="$(git rev-parse HEAD)"
git checkout -q -b other "$c1"; git commit -q --allow-empty -m side; side="$(git rev-parse HEAD)"

assert_ok "no previous release (argument absent) passes" zsh "$chk" "$c3"
assert_ok "no previous release (empty argument) passes" zsh "$chk" "$c3" ""
assert_ok "a strict descendant passes" zsh "$chk" "$c3" "$c1"
assert_ok "the direct child passes" zsh "$chk" "$c3" "$c2"
assert_fails "the same commit fails" zsh "$chk" "$c2" "$c2"
assert_fails "an ancestor fails" zsh "$chk" "$c1" "$c3"
assert_fails "an unrelated branch fails" zsh "$chk" "$side" "$c3"
assert_fails "a previous commit missing from the clone fails" zsh "$chk" "$c3" "0123456789abcdef0123456789abcdef01234567"
assert_fails "no candidate is refused" zsh "$chk"
assert_contains "$(zsh "$chk" "$c2" "$c2" 2>&1)" "newest release" "the failure explains itself"
finish
