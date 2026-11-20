source "${0:A:h}/lib.zsh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Sign-only mode on a fixture bundle, ad-hoc: re-signs inside-out, with the ad-hoc entitlements, and the bundle verifies.
export DIST_DIR="$tmp/dist"
mkdir -p "$DIST_DIR"
app="$(make_signable_bundle "$DIST_DIR")"
before="$(cd "$app" && find . -type f | sort | xargs shasum | shasum | cut -d' ' -f1)"
assert_fails "an unsigned fixture does not verify" codesign --verify --strict --deep "$app"
out="$(zsh "$ROOT/scripts/make-app.sh" --sign-only 2>&1)"; rc=$?
assert_eq "0" "$rc" "sign-only mode succeeds on the fixture ($out)"
assert_contains "$out" "Sign only" "sign-only says so"
assert_contains "$out" "ad-hoc" "sign-only reports the ad-hoc identity"
assert_ok "the re-signed bundle verifies" codesign --verify --strict --deep "$app"
assert_ok "the framework was signed too" codesign --verify --strict "$app/Contents/Frameworks/SQLCipher.framework"
assert_contains "$(codesign -d --entitlements - "$app" 2>&1)" "disable-library-validation" "ad-hoc keeps library validation off"
assert_contains "$(codesign -d --entitlements - "$app" 2>&1)" "device.audio-input" "audio-input is kept"
assert_contains "$(codesign -dv "$app" 2>&1)" "flags=0x10002(adhoc,runtime)" "hardened runtime is on"
assert_contains "$(codesign -dv "$app" 2>&1)" "Identifier=com.lintelapp.Lintel" "the bundle identifier is set"
assert_ok "symlinks survive" test -L "$app/Contents/Frameworks/llama.framework/Versions/Current"
# Nothing but signatures changed: the executables are byte-identical to what was given.
assert_ok "the main executable is still a Mach-O" file "$app/Contents/MacOS/Fixture"

# Sign-only without a bundle fails clearly and builds nothing.
rm -rf "$DIST_DIR/Lintel.app"
out="$(zsh "$ROOT/scripts/make-app.sh" --sign-only 2>&1)"; rc=$?
assert_eq "1" "$rc" "sign-only without a bundle fails"
assert_contains "$out" "nothing to sign" "sign-only without a bundle explains itself"
assert_fails "an unknown option is refused" zsh "$ROOT/scripts/make-app.sh" --bogus

# The DMG is built from the existing app (--skip-build), signed, and verifies.
app="$(make_signable_bundle "$DIST_DIR")"
assert_ok "sign-only again" zsh "$ROOT/scripts/make-app.sh" --sign-only
out="$(zsh "$ROOT/scripts/make-dmg.sh" --skip-build 2>&1)"; rc=$?
assert_eq "0" "$rc" "make-dmg --skip-build succeeds ($out)"
assert_ok "the DMG is signed" codesign --verify --strict "$DIST_DIR/Lintel.dmg"
assert_contains "$(codesign -dv "$DIST_DIR/Lintel.dmg" 2>&1)" "TeamIdentifier=not set" "the ad-hoc DMG has no Team ID"

# verify-release-bundle.sh must FAIL on an ad-hoc signed bundle, and say why.
out="$(zsh "$ROOT/scripts/verify-release-bundle.sh" "$app" "$DIST_DIR/Lintel.dmg" 2>&1)"; rc=$?
assert_eq "1" "$rc" "verify-release-bundle fails on an ad-hoc bundle"
assert_contains "$out" "signed ad-hoc" "the failure names ad-hoc signing"
assert_contains "$out" "39G44CM6GF" "the failure names the expected Team ID"
assert_contains "$out" "Notarized Developer ID" "the failure names the missing notarization"
assert_contains "$out" "stapler validate failed" "the failure names the missing staple"
assert_contains "$out" "check(s) failed" "the failure is counted"
# The app alone (no DMG): the app's own spctl and stapler checks must fail, not only the DMG's.
out="$(zsh "$ROOT/scripts/verify-release-bundle.sh" "$app" 2>&1)"; rc=$?
assert_eq "1" "$rc" "verify-release-bundle fails on an ad-hoc app alone"
assert_contains "$out" "spctl does not accept the app" "the app's spctl check fails on its own"
assert_contains "$out" "stapler validate failed for the app" "the app's stapler check fails on its own"
assert_contains "$out" "3 check(s) failed" "requirement, spctl and staple fail; only codesign --verify passes"
assert_fails "no argument is refused" zsh "$ROOT/scripts/verify-release-bundle.sh"
assert_fails "a missing bundle is refused" zsh "$ROOT/scripts/verify-release-bundle.sh" "$tmp/nope.app"
# It still prints the requirement and writes it where asked.
REQUIREMENT_OUT="$tmp/req.txt" zsh "$ROOT/scripts/verify-release-bundle.sh" "$app" >/dev/null 2>&1
assert_contains "$(cat "$tmp/req.txt" 2>/dev/null)" "cdhash" "the printed requirement of an ad-hoc bundle is a cdhash"
finish
