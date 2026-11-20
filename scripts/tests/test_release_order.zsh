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

assert_ok "no previous release (argument absent) passes" bash "$chk" "$c3"
assert_ok "no previous release (empty argument) passes" bash "$chk" "$c3" ""
assert_ok "a strict descendant passes" bash "$chk" "$c3" "$c1"
assert_ok "the direct child passes" bash "$chk" "$c3" "$c2"
assert_fails "the same commit fails" bash "$chk" "$c2" "$c2"
assert_fails "an ancestor fails" bash "$chk" "$c1" "$c3"
assert_fails "an unrelated branch fails" bash "$chk" "$side" "$c3"
assert_fails "a previous commit missing from the clone fails" bash "$chk" "$c3" "0123456789abcdef0123456789abcdef01234567"
assert_fails "no candidate is refused" bash "$chk"
assert_contains "$(bash "$chk" "$c2" "$c2" 2>&1)" "newest release" "the failure explains itself"

# --github: a stub `gh` answers `api --paginate ... --jq <filter>` by running the real filter (jq) over each page in
# $STUB_PAGES, the way gh applies --jq per page. Drafts and the current tag must be ignored, every page read, and the
# newest by published_at chosen.
git checkout -q main
git tag v0.1.0 "$c1"; git tag v0.2.0 "$c2"; git tag v0.3.0 "$c3"
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/bin/zsh
filter=""; paged=0
while (( $# )); do case "$1" in --jq) filter="$2"; shift 2 ;; --paginate) paged=1; shift ;; *) shift ;; esac; done
(( paged )) || STUB_PAGES="${STUB_PAGES%% *}"  # without --paginate only the first page arrives
for page in ${(s: :)STUB_PAGES}; do jq -r "$filter" "$page" || exit 1; done
STUB
chmod +x "$tmp/bin/gh"
page() { print -r -- "$2" > "$tmp/$1.json"; print -r -- "$tmp/$1.json"; }
p1="$(page p1 '[{"tag_name":"v0.9.0","draft":true,"published_at":null},{"tag_name":"v0.2.0","draft":false,"published_at":"2026-11-20T10:00:00Z"}]')"
p2="$(page p2 '[{"tag_name":"v0.1.0","draft":false,"published_at":"2026-11-19T10:00:00Z"}]')"
gh_check() { PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r STUB_PAGES="$1" bash "$chk" --github "$2" "$3"; }
assert_ok "--github: a descendant of the newest release passes" gh_check "$p1 $p2" "$c3" v0.3.0
assert_fails "--github: the newest release is found on any page and an older tag fails" gh_check "$p2 $p1" "$c1" v0.1.1
assert_contains "$(gh_check "$p1 $p2" "$c3" v0.3.0 2>&1)" "v0.2.0" "--github names the newest published release, not the draft"
p3="$(page p3 '[{"tag_name":"v0.3.0","draft":false,"published_at":"2026-11-21T10:00:00Z"}]')"
assert_ok "--github: the run's own tag (a re-run) is not its own predecessor" gh_check "$p1 $p2 $p3" "$c3" v0.3.0
assert_fails "--github: another newer release that is not an ancestor fails" gh_check "$p1 $p2 $p3" "$c2" v0.2.1
p4="$(page p4 '[]')"
assert_ok "--github: no release yet passes" gh_check "$p4" "$c1" v0.1.0
p5="$(page p5 '[{"tag_name":"v9.9.9","draft":false,"published_at":"2026-12-01T10:00:00Z"}]')"
assert_fails "--github: a newest release whose tag is not in the clone fails" gh_check "$p1 $p5" "$c3" v0.3.0
assert_fails "--github: a failing API call fails" gh_check "$tmp/missing.json" "$c3" v0.3.0
assert_fails "--github without GITHUB_REPOSITORY is refused" env -u GITHUB_REPOSITORY bash "$chk" --github "$c3" v0.3.0
finish
