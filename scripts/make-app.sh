#!/bin/zsh
# Builds dist/Lintel.app (dist/Lintel-QA.app for a debug build) from the Swift package.
#
# Usage: scripts/make-app.sh [--sign-only]
#   --sign-only  compile and assemble nothing: re-sign the existing bundle (dist/Lintel.app, or dist/Lintel-QA.app
#                for CONFIGURATION=debug) with SIGN_IDENTITY, inside-out, and check it. This is what the release
#                workflow's `sign` job runs on the ad-hoc bundle the `build` job made (or SIGN_ONLY=1).
#
# Environment:
#   CONFIGURATION  release (default) or debug. Debug builds accept the QA launch arguments (docs/qa.md) and are a
#                  different app from the owner's real Lintel: bundle id com.lintelapp.Lintel.QA, executable and
#                  process name Lintel-QA, no .lintellayouts document type (so Launch Services, Accessibility grants
#                  and name-matching tools can never confuse it with the real one).
#   SIGN_IDENTITY  code-signing identity; "-" (default) signs ad-hoc. The release workflow's `sign` job passes the
#                  SHA-1 of the imported Developer ID Application certificate. Never use that identity on a
#                  developer Mac (docs/signing.md). With a Team ID the signature uses the secure timestamp and
#                  Resources/Lintel.entitlements; without one --timestamp=none and Resources/Lintel-adhoc.entitlements
#                  (scripts/select-entitlements.sh decides from the signature, not from the name).
#   SIGN_KEYCHAIN  optional keychain to look the identity up in (the release workflow's temporary one).
#   DIST_DIR       where the bundle goes (default: dist/ in the repository); the script tests use a temporary one.
#   APP_VERSION    CFBundleShortVersionString to stamp (X.Y.Z or X.Y.Z-beta.N), together with APP_BUILD.
#   APP_BUILD      CFBundleVersion to stamp, a plain positive integer. Both are set by the release workflow
#                  (scripts/version-from-tag.sh, git rev-list --count HEAD); with neither set the bundle keeps what
#                  Resources/Info.plist says (0.0.0 / 0). Setting only one of them is an error. They are written into
#                  the copied Info.plist before any codesign (scripts/stamp-version.sh), never into the source file.
set -euo pipefail

APP_NAME="Lintel"
ROOT="${0:A:h:h}"
SIGN_ONLY="${SIGN_ONLY:-0}"
for arg in "$@"; do
  case "$arg" in
    --sign-only) SIGN_ONLY=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done
source "$ROOT/scripts/select-entitlements.sh"
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_VERSION="${APP_VERSION:-}"
APP_BUILD="${APP_BUILD:-}"
if [[ -n "$APP_VERSION" || -n "$APP_BUILD" ]] && [[ -z "$APP_VERSION" || -z "$APP_BUILD" ]]; then
  echo "APP_VERSION and APP_BUILD must be set together (or both left unset)" >&2
  exit 64
fi
case "$CONFIGURATION" in
  release|debug) ;;
  *) echo "CONFIGURATION must be release or debug, got: $CONFIGURATION" >&2; exit 64 ;;
esac
cd "$ROOT"

OUT="$DIST_DIR/$APP_NAME.app"
# A debug build is another app and goes to another path, so it never replaces the release bundle the DMG is made from.
[[ "$CONFIGURATION" == debug ]] && OUT="$DIST_DIR/$APP_NAME-QA.app"
EXEC_NAME="$APP_NAME"
BUNDLE_ID="com.lintelapp.Lintel"
if [[ "$CONFIGURATION" == debug ]]; then
  EXEC_NAME="Lintel-QA"
  BUNDLE_ID="com.lintelapp.Lintel.QA"
fi

if [[ "$SIGN_ONLY" == 1 ]]; then
  [[ -d "$OUT/Contents/MacOS" ]] || { echo "Missing $OUT: nothing to sign; run scripts/make-app.sh first" >&2; exit 1; }
  echo "Sign only: re-signing the existing $OUT"
else
  if [[ ! -f Packages/GRDBCipher/upstream/GRDB/Core/Database.swift ]]; then
    echo "The GRDB submodule is missing. Run: git submodule update --init" >&2
    exit 1
  fi

  swift build -c "$CONFIGURATION" --arch arm64 --product "$APP_NAME"
  BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --show-bin-path)"

  rm -rf "$OUT"
  mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$OUT/Contents/Frameworks"
  cp "$BIN_DIR/$APP_NAME" "$OUT/Contents/MacOS/$EXEC_NAME"
  cp Resources/Info.plist "$OUT/Contents/Info.plist"
  if [[ "$CONFIGURATION" == debug ]]; then
    PLIST_BUDDY=/usr/libexec/PlistBuddy
    "$PLIST_BUDDY" -c "Set :CFBundleIdentifier $BUNDLE_ID" "$OUT/Contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleExecutable $EXEC_NAME" "$OUT/Contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleName Lintel QA" "$OUT/Contents/Info.plist"
    "$PLIST_BUDDY" -c "Set :CFBundleDisplayName Lintel QA" "$OUT/Contents/Info.plist"
    # The real app owns the .lintellayouts association; the QA build must not compete for it.
    "$PLIST_BUDDY" -c "Delete :CFBundleDocumentTypes" "$OUT/Contents/Info.plist" 2>/dev/null || true
    "$PLIST_BUDDY" -c "Delete :UTExportedTypeDeclarations" "$OUT/Contents/Info.plist" 2>/dev/null || true
  fi
  # Stamp the version into the COPIED plist, before any codesign (a later change would break the signature).
  if [[ -n "$APP_VERSION" ]]; then
    "$ROOT/scripts/stamp-version.sh" "$OUT/Contents/Info.plist" "$APP_VERSION" "$APP_BUILD"
  fi
  printf 'APPL????' > "$OUT/Contents/PkgInfo"

  # SQLCipher is a dynamic framework (docs/decisions/0001-sqlite.md): embed it next to the binary.
  ditto "$BIN_DIR/SQLCipher.framework" "$OUT/Contents/Frameworks/SQLCipher.framework"

  # llama.cpp (docs/decisions/0005-builtin-llm.md): the XCFramework's macOS slice is universal, Lintel is arm64 only,
  # so the embedded copy keeps the arm64 slice (half the size).
  ditto "$BIN_DIR/llama.framework" "$OUT/Contents/Frameworks/llama.framework"
  lipo -thin arm64 "$OUT/Contents/Frameworks/llama.framework/Versions/A/llama" \
    -output "$OUT/Contents/Frameworks/llama.framework/Versions/A/llama.arm64"
  mv "$OUT/Contents/Frameworks/llama.framework/Versions/A/llama.arm64" \
    "$OUT/Contents/Frameworks/llama.framework/Versions/A/llama"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$OUT/Contents/MacOS/$EXEC_NAME"

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

  # The recorder's own strings ("Record Shortcut", "Press Shortcut") have no Polish in the library; ours go into its bundle.
  mkdir -p "$OUT/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Resources/pl.lproj"
  cp Resources/KeyboardShortcuts/pl.lproj/Localizable.strings \
    "$OUT/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Resources/pl.lproj/Localizable.strings"

  # Localizations: compile the String Catalog into <lang>.lproj/Localizable.strings.
  xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$OUT/Contents/Resources"
  # The microphone usage description is looked up in InfoPlist.strings of the user's language.
  xcrun xcstringstool compile Resources/InfoPlist.xcstrings --output-directory "$OUT/Contents/Resources"

  # Asset catalog: the app icon (AppIcon.icns) and the brand AccentColor (Assets.car), named in Info.plist.
  # (The partial Info.plist only repeats the keys Resources/Info.plist already has; actool wants somewhere to put it.)
  ACTOOL_PLIST="$(mktemp)"
  xcrun actool Resources/Assets.xcassets --compile "$OUT/Contents/Resources" --platform macosx \
    --minimum-deployment-target 26.0 --app-icon AppIcon --accent-color AccentColor \
    --output-format human-readable-text --output-partial-info-plist "$ACTOOL_PLIST" --notices --warnings >/dev/null
  rm -f "$ACTOOL_PLIST"
  [[ -f "$OUT/Contents/Resources/AppIcon.icns" ]] || { echo "actool did not produce AppIcon.icns" >&2; exit 1; }

  plutil -lint "$OUT/Contents/Info.plist" >/dev/null
fi

# Sign inside-out: the embedded frameworks first, then the app, all with the hardened runtime. A Developer ID identity
# has a Team ID: it gets Apple's secure timestamp (notarization requires it) and Resources/Lintel.entitlements, whose
# frameworks load under library validation. An ad-hoc identity has none: --timestamp=none and
# Resources/Lintel-adhoc.entitlements, which turns library validation off (docs/signing.md). A probe signature tells
# which case it is, so the choice never depends on the identity's name.
SIGN_PROBE="$(probe_signing_identity "$SIGN_IDENTITY" "$SIGN_KEYCHAIN")"
SIGN_TIMESTAMP="$(signing_timestamp_arg "$SIGN_PROBE")"
SIGN_ENTITLEMENTS="$(select_entitlements "$SIGN_PROBE")"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" "$SIGN_TIMESTAMP" --options runtime)
[[ -n "$SIGN_KEYCHAIN" ]] && SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
codesign "${SIGN_ARGS[@]}" "$OUT/Contents/Frameworks/SQLCipher.framework"
codesign "${SIGN_ARGS[@]}" "$OUT/Contents/Frameworks/llama.framework"
codesign "${SIGN_ARGS[@]}" --identifier "$BUNDLE_ID" --entitlements "$SIGN_ENTITLEMENTS" "$OUT"
codesign --verify --strict --deep "$OUT"

# The check that matters runs on the finished, signed bundle (not on the file the copy above just wrote): the
# Polish recorder strings must be inside the library's bundle and identical to ours.
BUILT_PL="$OUT/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle/Contents/Resources/pl.lproj/Localizable.strings"
cmp -s Resources/KeyboardShortcuts/pl.lproj/Localizable.strings "$BUILT_PL" \
  || { echo "The Polish recorder strings did not reach the built KeyboardShortcuts bundle" >&2; exit 1; }

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUT/Contents/Info.plist")"
BUILT_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/Contents/Info.plist")"
SIGNED_WITH="an identity without a Team ID"
[[ "$SIGN_TIMESTAMP" != --timestamp ]] || SIGNED_WITH="an identity with a Team ID"
[[ "$SIGN_IDENTITY" != - ]] || SIGNED_WITH=ad-hoc
echo "Built: $OUT ($CONFIGURATION, version $BUILT_VERSION ($BUILT_BUILD), signed with $SIGNED_WITH, ${SIGN_ENTITLEMENTS:t})"
