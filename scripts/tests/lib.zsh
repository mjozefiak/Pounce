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

# A fixture app bundle: Info.plist, a signable executable, the embedded frameworks make-app.sh signs (Sparkle with its nested helpers) and the
# Polish recorder strings it compares. Prints the path. Needs $tmp (a temporary directory) from the caller.
make_signable_bundle() {
  local dist="$1" app fw
  app="$dist/Lintel.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
  cp "$FIXTURES/Info.fixture.plist" "$app/Contents/Info.plist"
  cp /usr/bin/true "$app/Contents/MacOS/Fixture"
  for fw in SQLCipher llama; do
    mkdir -p "$app/Contents/Frameworks/$fw.framework/Versions/A/Resources"
    cp /usr/bin/true "$app/Contents/Frameworks/$fw.framework/Versions/A/$fw"
    sed "s/Fixture/$fw/; s/com.example.fixture/com.example.$fw/; s/APPL/FMWK/" "$FIXTURES/Info.fixture.plist" \
      > "$app/Contents/Frameworks/$fw.framework/Versions/A/Resources/Info.plist"
    ln -s A "$app/Contents/Frameworks/$fw.framework/Versions/Current"
    ln -s Versions/Current/$fw "$app/Contents/Frameworks/$fw.framework/$fw"
    ln -s Versions/Current/Resources "$app/Contents/Frameworks/$fw.framework/Resources"
  done
  # Sparkle's layout: version B, a helper tool and a helper app nested in the framework (no XPC services).
  local sparkle="$app/Contents/Frameworks/Sparkle.framework"
  mkdir -p "$sparkle/Versions/B/Resources" "$sparkle/Versions/B/Updater.app/Contents/MacOS"
  cp /usr/bin/true "$sparkle/Versions/B/Sparkle"
  cp /usr/bin/true "$sparkle/Versions/B/Autoupdate"
  cp /usr/bin/true "$sparkle/Versions/B/Updater.app/Contents/MacOS/Updater"
  sed "s/Fixture/Sparkle/; s/com.example.fixture/com.example.Sparkle/; s/APPL/FMWK/" "$FIXTURES/Info.fixture.plist" \
    > "$sparkle/Versions/B/Resources/Info.plist"
  sed "s/Fixture/Updater/; s/com.example.fixture/com.example.Updater/" "$FIXTURES/Info.fixture.plist" \
    > "$sparkle/Versions/B/Updater.app/Contents/Info.plist"
  ln -s B "$sparkle/Versions/Current"
  ln -s Versions/Current/Sparkle "$sparkle/Sparkle"
  ln -s Versions/Current/Resources "$sparkle/Resources"
  ln -s Versions/Current/Autoupdate "$sparkle/Autoupdate"
  ln -s Versions/Current/Updater.app "$sparkle/Updater.app"
  local pl="$app/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Resources/pl.lproj"
  mkdir -p "$pl"
  cp "$ROOT/Resources/KeyboardShortcuts/pl.lproj/Localizable.strings" "$pl/Localizable.strings"
  print -r -- "$app"
}
