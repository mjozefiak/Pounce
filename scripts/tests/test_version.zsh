source "${0:A:h}/lib.zsh"
vft="$ROOT/scripts/version-from-tag.sh"
stamp="$ROOT/scripts/stamp-version.sh"
pb=/usr/libexec/PlistBuddy
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# version-from-tag.sh: valid tags
assert_eq "0.1.0" "$("$vft" v0.1.0)" "release tag"
assert_eq "0.1.0-beta.1" "$("$vft" v0.1.0-beta.1)" "beta tag"
assert_eq "10.20.30-beta.12" "$("$vft" v10.20.30-beta.12)" "multi-digit numbers"
assert_eq "0.0.0" "$("$vft" v0.0.0)" "zero version"
assert_eq "false" "$("$vft" --is-prerelease v0.1.0)" "release is not a pre-release"
assert_eq "true" "$("$vft" --is-prerelease v0.1.0-beta.1)" "beta is a pre-release"

# invalid tags: non-zero exit, message on stderr, nothing on stdout
for bad in v0.1 v0.1.0-rc.1 v01.0.0 v0.1.0-beta.0 v0.1.0-beta.01 0.1.0 "" v0.1.0.0 v0.1.0-beta v0.1.0-beta.1.2 V0.1.0 " v0.1.0" $'v0.1.0\n'; do
  assert_fails "tag '$bad' is rejected" "$vft" "$bad"
  assert_eq "" "$("$vft" "$bad" 2>/dev/null)" "tag '$bad' prints nothing on stdout"
  assert_contains "$("$vft" "$bad" 2>&1 >/dev/null)" "Not a release tag" "tag '$bad' explains itself on stderr"
  assert_fails "tag '$bad' is rejected by --is-prerelease" "$vft" --is-prerelease "$bad"
done
assert_fails "no argument is rejected" "$vft"
assert_fails "two arguments are rejected" "$vft" v0.1.0 v0.1.1

# stamp-version.sh on a fixture bundle
make_bundle() {
  local app="$tmp/$1.app"
  mkdir -p "$app/Contents/MacOS"
  cp "$FIXTURES/Info.fixture.plist" "$app/Contents/Info.plist"
  cp /usr/bin/true "$app/Contents/MacOS/Fixture"
  print -r -- "$app"
}
app="$(make_bundle stamped)"
assert_ok "stamps a release version" "$stamp" "$app/Contents/Info.plist" 0.1.0 123
assert_eq "0.1.0" "$("$pb" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" "short version read back"
assert_eq "123" "$("$pb" -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" "build read back"
assert_ok "stamps a beta version" "$stamp" "$app/Contents/Info.plist" 0.1.0-beta.2 4567
assert_eq "0.1.0-beta.2" "$("$pb" -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" "beta read back"
assert_eq "4567" "$("$pb" -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" "second build read back"
assert_eq "com.example.fixture" "$("$pb" -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" "other keys untouched"
assert_ok "the stamped plist is valid" plutil -lint "$app/Contents/Info.plist"

# the source fixture is never edited by a stamp on a copy
assert_eq "0.0.0" "$("$pb" -c 'Print :CFBundleShortVersionString' "$FIXTURES/Info.fixture.plist")" "fixture untouched"

# rejects bad input and leaves the plist alone
bad="$(make_bundle bad)"
before="$(shasum "$bad/Contents/Info.plist")"
for b in abc 1.5 0 01 -1 "" "12 3" 1e3 +5; do
  assert_fails "build '$b' is rejected" "$stamp" "$bad/Contents/Info.plist" 0.1.0 "$b"
done
for v in 1.0 v0.1.0 0.1.0-rc.1 01.0.0 0.1.0-beta.0 "" 0.1.0-; do
  assert_fails "version '$v' is rejected" "$stamp" "$bad/Contents/Info.plist" "$v" 5
done
assert_contains "$("$stamp" "$bad/Contents/Info.plist" 0.1.0 abc 2>&1)" "plain positive integer" "build message"
assert_eq "$before" "$(shasum "$bad/Contents/Info.plist")" "a rejected stamp leaves the plist untouched"
assert_fails "a missing plist is rejected" "$stamp" "$tmp/nope.plist" 0.1.0 5

# the order matters: an ad-hoc signature made AFTER stamping verifies, a stamp AFTER signing breaks it
signed="$(make_bundle signed)"
"$stamp" "$signed/Contents/Info.plist" 0.1.0-beta.1 99
assert_ok "ad-hoc signing after stamping succeeds" codesign --force --sign - --timestamp=none "$signed"
assert_ok "the signature verifies after stamping before signing" codesign --verify --strict "$signed"
assert_eq "99" "$("$pb" -c 'Print :CFBundleVersion' "$signed/Contents/Info.plist")" "build survives signing"
"$stamp" "$signed/Contents/Info.plist" 0.1.0-beta.1 100
assert_fails "a stamp after signing breaks the signature (why make-app.sh stamps first)" codesign --verify --strict "$signed"

# make-app.sh: the pairing rule is checked before anything is built
assert_fails "APP_VERSION without APP_BUILD is rejected" env -u APP_BUILD APP_VERSION=0.1.0 "$ROOT/scripts/make-app.sh"
assert_fails "APP_BUILD without APP_VERSION is rejected" env -u APP_VERSION APP_BUILD=5 "$ROOT/scripts/make-app.sh"
assert_contains "$(env -u APP_BUILD APP_VERSION=0.1.0 "$ROOT/scripts/make-app.sh" 2>&1)" "must be set together" "pairing message"

# the source plist is the local-build placeholder
assert_eq "0.0.0" "$("$pb" -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")" "Resources/Info.plist version"
assert_eq "0" "$("$pb" -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist")" "Resources/Info.plist build"
finish
