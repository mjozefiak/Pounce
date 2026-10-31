#!/bin/zsh
# Builds dist/Pounce.app from the Swift package.
#
# Environment:
#   CONFIGURATION  release (default) or debug. Debug builds accept the QA launch arguments (docs/qa.md).
#   SIGN_IDENTITY  code-signing identity; "-" (default) signs ad-hoc. The release workflow passes
#                  "Pounce Release". Never use that identity on a developer Mac (docs/signing.md).
#   SIGN_KEYCHAIN  optional keychain to look the identity up in (the release workflow's temporary one).
set -euo pipefail

APP_NAME="Pounce"
ROOT="${0:A:h:h}"
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"
case "$CONFIGURATION" in
  release|debug) ;;
  *) echo "CONFIGURATION must be release or debug, got: $CONFIGURATION" >&2; exit 64 ;;
esac
cd "$ROOT"

if [[ ! -f Packages/GRDBCipher/upstream/GRDB/Core/Database.swift ]]; then
  echo "The GRDB submodule is missing. Run: git submodule update --init" >&2
  exit 1
fi

swift build -c "$CONFIGURATION" --arch arm64 --product "$APP_NAME"
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"

OUT="$ROOT/dist/$APP_NAME.app"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"
cp "$BIN_DIR/$APP_NAME" "$OUT/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"

# SQLCipher is a dynamic framework (docs/decisions/0001-sqlite.md): embed it next to the binary.
ditto "$BIN_DIR/SQLCipher.framework" "$OUT/Contents/Frameworks/SQLCipher.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$OUT/Contents/MacOS/$APP_NAME"

# License notices of the bundled third-party code (SQLCipher's BSD license requires them in binary
# distributions).
cp Resources/THIRD_PARTY_NOTICES.txt "$OUT/Contents/Resources/THIRD_PARTY_NOTICES.txt"

# Resource bundles of package dependencies (KeyboardShortcuts' recorder strings). The generated
# `Bundle.module` accessor looks for them in Contents/Resources and traps when one is missing.
for bundle in "$BIN_DIR"/*.bundle(N); do
  ditto "$bundle" "$OUT/Contents/Resources/${bundle:t}"
done
if [[ ! -d "$OUT/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle" ]]; then
  echo "The KeyboardShortcuts resource bundle is missing from $BIN_DIR" >&2
  exit 1
fi

# Localizations: compile the String Catalog into <lang>.lproj/Localizable.strings.
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$OUT/Contents/Resources"

plutil -lint "$OUT/Contents/Info.plist" >/dev/null

# Sign inside-out: the embedded framework first, then the app, both with the hardened runtime. A
# self-signed identity has no Team ID, so the app's entitlements turn library validation off to let it
# load the framework (Resources/Pounce.entitlements, docs/signing.md).
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none --options runtime)
[[ -n "$SIGN_KEYCHAIN" ]] && SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
codesign "${SIGN_ARGS[@]}" "$OUT/Contents/Frameworks/SQLCipher.framework"
codesign "${SIGN_ARGS[@]}" --identifier app.pounce.Pounce --entitlements Resources/Pounce.entitlements "$OUT"
codesign --verify --strict --deep "$OUT"

echo "Built: $OUT ($CONFIGURATION, signed with ${SIGN_IDENTITY/#-/ad-hoc})"
