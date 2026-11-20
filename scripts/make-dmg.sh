#!/bin/zsh
# Builds dist/Lintel.dmg: a drag-and-drop installer with Lintel.app and an Applications shortcut.
#
# Usage: scripts/make-dmg.sh [--skip-build]
#   --skip-build  reuse an existing dist/Lintel.app (or set SKIP_BUILD=1)
# The version comes from the built bundle (scripts/make-app.sh stamps APP_VERSION / APP_BUILD into it).
# Signing uses the same SIGN_IDENTITY / SIGN_KEYCHAIN as scripts/make-app.sh (ad-hoc by default); an identity with a
# Team ID gets the secure timestamp, any other --timestamp=none (scripts/select-entitlements.sh).
# DIST_DIR overrides the dist/ directory (the script tests use a temporary one).
# --skip-build is also how the release workflow's `sign` job builds the DMG from the signed, stapled app.
set -euo pipefail

APP_NAME="Lintel"
VOL_NAME="Lintel"
ROOT="${0:A:h:h}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done
cd "$ROOT"
source "$ROOT/scripts/select-entitlements.sh"

[[ "$SKIP_BUILD" == 1 ]] || "$ROOT/scripts/make-app.sh"
APP="$DIST_DIR/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Missing $APP: run scripts/make-app.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST_DIR/$APP_NAME.dmg"
DMG_VERSIONED="$DIST_DIR/$APP_NAME-$VERSION.dmg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STAGE="$TMP/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG" "$DMG_VERSIONED"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ -format ULFO "$DMG"

SIGN_TIMESTAMP="$(signing_timestamp_arg "$(probe_signing_identity "$SIGN_IDENTITY" "$SIGN_KEYCHAIN")")"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" "$SIGN_TIMESTAMP")
[[ -n "$SIGN_KEYCHAIN" ]] && SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
codesign "${SIGN_ARGS[@]}" "$DMG"
hdiutil verify -quiet "$DMG"
cp "$DMG" "$DMG_VERSIONED"

echo "Built: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), version $VERSION)"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
