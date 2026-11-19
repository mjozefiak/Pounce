source "${0:A:h}/lib.zsh"
section="$ROOT/scripts/changelog-section.sh"
run() { local f="$1"; shift; CHANGELOG="$FIXTURES/$f" "$section" "$@"; }
runerr() { local f="$1"; shift; CHANGELOG="$FIXTURES/$f" "$section" "$@" 2>&1 >/dev/null; }

# normal: exactly the body between the headings, nothing else
expected=$'### Added\n\n- New thing.\n- Another thing.\n\n### Fixed\n\n- A bug.'
assert_eq "$expected" "$(run changelog-normal.md 1.1.0)" "1.1.0 body"
assert_eq $'### Added\n\n- First release.' "$(run changelog-normal.md 1.0.0)" "last section body"
assert_eq $'### Added\n\n- Something pending.' "$(run changelog-normal.md Unreleased)" "Unreleased accepted as a name"
assert_fails "a version without a section fails" run changelog-normal.md 2.0.0
assert_contains "$(runerr changelog-normal.md 2.0.0)" "no section for 2.0.0" "missing-section message"
assert_fails "1.1 is not a version" run changelog-normal.md 1.1
assert_fails "a prefix of a version does not match" run changelog-normal.md 1.1.00

# pre-release versions are exact names, not prefixes
assert_eq $'### Added\n\n- Beta feature.' "$(run changelog-prerelease.md 0.1.0-beta.1)" "pre-release body"
assert_eq $'### Added\n\n- Final.' "$(run changelog-prerelease.md 0.1.0)" "release body next to its pre-release"
assert_fails "a pre-release without a section fails" run changelog-prerelease.md 0.1.0-beta.2
assert_fails "a malformed pre-release fails" run changelog-prerelease.md 0.1.0-
assert_fails "a v prefix is not a version" run changelog-prerelease.md v0.1.0

# malformed versions are usage errors (64), not missing sections (1)
code() { run "$@" >/dev/null 2>&1; print -r -- $?; }
assert_eq 64 "$(code changelog-normal.md 1.1)" "1.1 exits 64"
assert_eq 64 "$(code changelog-normal.md '1.0.0|Unreleased')" "an alternation is not a version"
assert_eq 64 "$(code changelog-normal.md '.*')" "a regex is not a version"
assert_eq 1 "$(code changelog-normal.md 2.0.0)" "a missing section exits 1"

# link-reference definitions at the end of the file are not part of the last section
assert_eq $'### Added\n\n- First beta.' "$(run changelog-links.md 0.1.0-beta.1)" "last section without the link footer"
assert_eq $'### Fixed\n\n- See [the guide][guide].\n\n[guide]: https://example.com/guide' \
  "$(run changelog-links.md 0.2.0)" "a definition inside a section is kept"

# duplicate
assert_fails "a duplicated version fails" run changelog-duplicate.md 1.0.0
assert_contains "$(runerr changelog-duplicate.md 1.0.0)" "2 sections for 1.0.0" "duplicate message"
assert_ok "a duplicate elsewhere does not break an empty Unreleased" run changelog-duplicate.md Unreleased

# unreleased only
assert_eq $'### Added\n\n- Only pending work.' "$(run changelog-unreleased-only.md Unreleased)" "Unreleased-only body"
assert_fails "no release section when only Unreleased exists" run changelog-unreleased-only.md 1.0.0

# empty sections
assert_ok "an empty Unreleased prints nothing and succeeds" run changelog-empty-unreleased.md Unreleased
assert_eq "" "$(run changelog-empty-unreleased.md Unreleased)" "empty Unreleased is empty output"
assert_fails "an empty versioned section fails" run changelog-empty-version.md 1.0.0
assert_contains "$(runerr changelog-empty-version.md 1.0.0)" "empty" "empty-section message"
assert_fails "a missing file fails" env CHANGELOG="$FIXTURES/nope.md" "$section" 1.0.0

# the real changelog
assert_ok "the real CHANGELOG.md has an Unreleased section" "$section" Unreleased
assert_fails "the real CHANGELOG.md has no 99.0.0 section" "$section" 99.0.0
finish
