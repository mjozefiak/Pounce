#!/bin/zsh
# Signs the DMG, builds the update feed and signs it: the body of the release workflow's step "Sign the DMG and build
# the appcast". Every failure is fatal; nothing here is allowed to be skipped or ignored (ReleaseWorkflowTests pin that
# for the step that calls it).
#
# Usage: scripts/release-appcast.sh <Info.plist of the built app> <Lintel.dmg> <work-dir>
#   <work-dir>/previous/appcast.xml   optional: the previous release's feed (scripts/fetch-previous-appcast.sh). Present
#                                     means it MUST verify against the Sparkle key, or this fails: dropping it would
#                                     remove the other channel's item.
#   <work-dir>/appcast.xml            written for a tag run only (built and signed in a temporary name, moved at the end)
# Environment: IS_TAG_RUN (true|false), GITHUB_REF_NAME (the tag, tag runs), SPARKLE_SIGN_UPDATE, SPARKLE_ED_PRIVATE_KEY.
#   CHANGELOG (optional, for tests) is read by scripts/changelog-section.sh.
#
# A run that is not a tag run (a manual `sign: true` run) builds, signs and verifies the feed, to exercise the secret and
# the pipeline, and then DELETES it: that feed is for version 0.0.0 and validly signed with the production key, and an
# artifact would hand it to everyone who can read the run. It prints the item count and that verification passed.
#
# Only scripts/sparkle-sign.sh sees SPARKLE_ED_PRIVATE_KEY (and passes it to sign_update alone); every other command
# runs without it.
set -euo pipefail
HERE="${0:A:h}"
PLIST="${1:-}" DMG="${2:-}" WORK="${3:-}"
die() { print -u2 -r -- "::error::$1"; exit "${2:-1}"; }
[[ -f "$PLIST" && -f "$DMG" && -n "$WORK" ]] || die "usage: release-appcast.sh <Info.plist> <Lintel.dmg> <work-dir>" 64
[[ "${IS_TAG_RUN:-}" == true || "${IS_TAG_RUN:-}" == false ]] || die "IS_TAG_RUN must be true or false" 64
mkdir -p "$WORK"
nokey() { env -u SPARKLE_ED_PRIVATE_KEY "$@"; }

VERSION="$(nokey plutil -extract CFBundleShortVersionString raw "$PLIST")"
BUILD="$(nokey plutil -extract CFBundleVersion raw "$PLIST")"
STAGE="$(mktemp -d "$WORK/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

if [[ "$IS_TAG_RUN" == true ]]; then
  [[ -n "${GITHUB_REF_NAME:-}" ]] || die "GITHUB_REF_NAME is not set" 64
  TAG_VERSION="$(nokey "$HERE/version-from-tag.sh" "$GITHUB_REF_NAME")"
  [[ "$VERSION" == "$TAG_VERSION" ]] || die "The app says version $VERSION, the tag says $GITHUB_REF_NAME."
  nokey "$HERE/changelog-section.sh" "$VERSION" > "$STAGE/notes.md"
else
  print -r -- "A test build from a manual run. Nothing is published." > "$STAGE/notes.md"
fi

PREVIOUS=()
if [[ -f "$WORK/previous/appcast.xml" ]]; then
  "$HERE/sparkle-sign.sh" verify-feed "$WORK/previous/appcast.xml"
  PREVIOUS=(--previous "$WORK/previous/appcast.xml")
fi

DMG_SIGNATURE="$("$HERE/sparkle-sign.sh" sign-file "$DMG")"
nokey "$HERE/make-appcast.sh" --version "$VERSION" --build "$BUILD" --dmg "$DMG" \
  --signature "$DMG_SIGNATURE" --notes "$STAGE/notes.md" --info-plist "$PLIST" \
  --pub-date "$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')" --output "$STAGE/appcast.xml" "${PREVIOUS[@]}"
"$HERE/sparkle-sign.sh" sign-feed "$STAGE/appcast.xml"
"$HERE/sparkle-sign.sh" verify-feed "$STAGE/appcast.xml"
nokey xmllint --noout "$STAGE/appcast.xml"
ITEMS="$(grep -c '^        <item>$' "$STAGE/appcast.xml")"

if [[ "$IS_TAG_RUN" == true ]]; then
  mv "$STAGE/appcast.xml" "$WORK/appcast.xml"
  print -r -- "The feed has $ITEMS item(s) and its signature verified."
else
  rm -f "$STAGE/appcast.xml" "$WORK/appcast.xml"
  print -r -- "Test run: the feed was built with $ITEMS item(s) and its signature verified. It is not kept or uploaded."
fi
