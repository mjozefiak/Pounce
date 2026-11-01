#!/bin/zsh
# Builds dist/Pounce.dmg: a drag-and-drop installer with Pounce.app and an Applications shortcut.
#
# Usage: scripts/make-dmg.sh [--skip-build]
#   --skip-build  reuse an existing dist/Pounce.app (or set SKIP_BUILD=1)
# Signing uses the same SIGN_IDENTITY / SIGN_KEYCHAIN as scripts/make-app.sh (ad-hoc by default).
set -euo pipefail

APP_NAME="Pounce"
VOL_NAME="Pounce"
ROOT="${0:A:h:h}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_KEYCHAIN="${SIGN_KEYCHAIN:-}"
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done
cd "$ROOT"

[[ "$SKIP_BUILD" == 1 ]] || "$ROOT/scripts/make-app.sh"
APP="$ROOT/dist/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Missing $APP: run scripts/make-app.sh first" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/dist/$APP_NAME.dmg"
DMG_VERSIONED="$ROOT/dist/$APP_NAME-$VERSION.dmg"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STAGE="$TMP/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG" "$DMG_VERSIONED"
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL_NAME" -fs HFS+ -format ULFO "$DMG"

SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --timestamp=none)
[[ -n "$SIGN_KEYCHAIN" ]] && SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
codesign "${SIGN_ARGS[@]}" "$DMG"
hdiutil verify -quiet "$DMG"
cp "$DMG" "$DMG_VERSIONED"

echo "Built: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), version $VERSION)"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
