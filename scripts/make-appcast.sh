#!/bin/zsh
# Builds the update feed (appcast.xml, Sparkle RSS) for the release being built. Pure: no network, no key, no signing.
#
# Usage: scripts/make-appcast.sh --version <x.y.z[-beta.N]> --build <number> --dmg <Lintel.dmg> --signature <base64>
#            --notes <markdown file> --output <appcast.xml> [--previous <appcast.xml>] [--info-plist <Info.plist>]
#            [--pub-date <RFC 822 date>] [--repo <owner/name>]
#   --version    the tag without "v" (scripts/version-from-tag.sh); a "-beta.N" version is a pre-release
#   --build      CFBundleVersion, the commit count; becomes sparkle:version
#   --dmg        the notarized, stapled DMG; only its size is read (enclosure length)
#   --signature  the DMG's EdDSA signature, from `sign_update --ed-key-file - -p` (public data, not a secret)
#   --notes      the changelog section (scripts/changelog-section.sh), Markdown, XML-escaped into the item
#   --previous   the previous release's feed, signature already verified by the caller; it is only read. The
#                signature comment at its end is ignored here (the caller signs the new file).
#   --info-plist where sparkle:minimumSystemVersion (LSMinimumSystemVersion) is read; default Resources/Info.plist
#
# The feed holds at most two items (spec 2026-11-19-updates-and-open-source-hygiene, "The feed"):
#   - this release;
#   - the other channel's item, carried from --previous byte for byte (its DMG did not change, so its enclosure
#     signature stays valid): when this release is stable, the previous beta only if its sparkle:version is higher
#     than this build (otherwise it is dropped); when this release is a beta, the previous stable item.
# A beta item carries <sparkle:channel>beta</sparkle:channel>; a stable item has no channel.
# Fails (exit 1, nothing written) when --previous is not well-formed XML, holds an item this script would not have
# written, or when a beta is not newer than the stable it would sit beside. Exit 64 on usage errors.
set -euo pipefail

die() { print -u2 -r -- "make-appcast.sh: $1"; exit "${2:-1}"; }

VERSION="" BUILD="" DMG="" SIGNATURE="" NOTES="" OUTPUT="" PREVIOUS="" PUB_DATE=""
PLIST="${0:A:h:h}/Resources/Info.plist"
REPO="mjozefiak/lintel"
while (( $# )); do
  (( $# >= 2 )) || die "$1 needs a value" 64
  case "$1" in
    --version) VERSION="$2" ;;
    --build) BUILD="$2" ;;
    --dmg) DMG="$2" ;;
    --signature) SIGNATURE="$2" ;;
    --notes) NOTES="$2" ;;
    --output) OUTPUT="$2" ;;
    --previous) PREVIOUS="$2" ;;
    --info-plist) PLIST="$2" ;;
    --pub-date) PUB_DATE="$2" ;;
    --repo) REPO="$2" ;;
    *) die "unknown option $1" 64 ;;
  esac
  shift 2
done
for v in VERSION BUILD DMG SIGNATURE NOTES OUTPUT; do
  [[ -n "${(P)v}" ]] || die "--${(L)v} is required" 64
done
[[ "$VERSION" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$' ]] \
  || die "not a version: '$VERSION'" 64
[[ "$BUILD" =~ '^[1-9][0-9]{0,9}$' ]] || die "not a build number: '$BUILD'" 64
[[ "$SIGNATURE" =~ '^[A-Za-z0-9+/]{20,}={0,2}$' ]] || die "not a base64 signature" 64
[[ "$REPO" =~ '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' ]] || die "not an owner/name: '$REPO'" 64
[[ -f "$DMG" ]] || die "no DMG at $DMG" 64
[[ -s "$NOTES" ]] || die "release notes missing or empty: $NOTES" 64
[[ -z "$PREVIOUS" || -f "$PREVIOUS" ]] || die "no previous feed at $PREVIOUS" 64
command -v xmllint >/dev/null || die "xmllint is required"
MIN_SYSTEM="$(plutil -extract LSMinimumSystemVersion raw "$PLIST" 2>/dev/null)" \
  || die "LSMinimumSystemVersion is missing in $PLIST"
[[ "$MIN_SYSTEM" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || die "odd LSMinimumSystemVersion '$MIN_SYSTEM'"
[[ -z "$PUB_DATE" || "$PUB_DATE" =~ '^[A-Za-z0-9 ,:+-]+$' ]] || die "odd --pub-date" 64
LENGTH="$(stat -f %z "$DMG")"

escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

[[ "$VERSION" == *-beta.* ]] && IS_BETA=1 || IS_BETA=0
TAG="v$VERSION"

# The item of this release. The notes keep their line breaks; & < > are escaped, so nothing in them can end the element.
NEW_ITEM="        <item>
            <title>Lintel $VERSION</title>"
[[ -z "$PUB_DATE" ]] || NEW_ITEM+="
            <pubDate>$PUB_DATE</pubDate>"
NEW_ITEM+="
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>"
(( IS_BETA )) && NEW_ITEM+="
            <sparkle:channel>beta</sparkle:channel>"
NEW_ITEM+="
            <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
            <description sparkle:format=\"markdown\">$(escape < "$NOTES")</description>
            <enclosure url=\"https://github.com/$REPO/releases/download/$TAG/Lintel.dmg\" length=\"$LENGTH\" type=\"application/x-apple-diskimage\" sparkle:edSignature=\"$SIGNATURE\" />
        </item>"

# The previous feed: well-formed, at most one item per channel, each in the layout this script writes.
PREV_STABLE="" PREV_BETA="" PREV_STABLE_BUILD=0 PREV_BETA_BUILD=0
if [[ -n "$PREVIOUS" ]]; then
  xmllint --noout "$PREVIOUS" 2>/dev/null || die "the previous feed is not well-formed XML"
  [[ "$(xmllint --xpath 'count(/rss/channel)' "$PREVIOUS" 2>/dev/null)" == 1 ]] || die "the previous feed is not an RSS feed with one channel"
  EXPECTED="$(xmllint --xpath 'count(/rss/channel/item)' "$PREVIOUS")"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  # Each <item> ... </item> block, verbatim, into $TMP/item.N
  awk -v dir="$TMP" '
    /^[ \t]*<item>[ \t]*$/ { n++; inside = 1 }
    inside { print > (dir "/item." n) }
    /^[ \t]*<\/item>[ \t]*$/ { inside = 0 }
  ' "$PREVIOUS"
  typeset -a BLOCKS
  BLOCKS=("$TMP"/item.*(N))
  (( ${#BLOCKS} == EXPECTED )) || die "the previous feed has items this script did not write (found ${#BLOCKS} of $EXPECTED)"
  (( EXPECTED <= 2 )) || die "the previous feed has more than two items"
  for block in $BLOCKS; do
    { print '<r xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'; cat "$block"; print '</r>'; } > "$block.xml"
    xmllint --noout "$block.xml" 2>/dev/null || die "an item of the previous feed is not well-formed"
    b="$(xmllint --xpath 'string(//*[local-name()="version"])' "$block.xml")"
    c="$(xmllint --xpath 'string(//*[local-name()="channel"])' "$block.xml")"
    [[ "$b" =~ '^[1-9][0-9]{0,9}$' ]] || die "an item of the previous feed has no valid sparkle:version"
    text="$(<"$block")"
    if [[ "$c" == beta ]]; then
      [[ -z "$PREV_BETA" ]] || die "the previous feed has two beta items"
      PREV_BETA="$text" PREV_BETA_BUILD="$b"
    elif [[ -z "$c" ]]; then
      [[ -z "$PREV_STABLE" ]] || die "the previous feed has two stable items"
      PREV_STABLE="$text" PREV_STABLE_BUILD="$b"
    else
      die "an item of the previous feed has the unknown channel '$c'"
    fi
  done
fi

STABLE_ITEM="" BETA_ITEM=""
if (( IS_BETA )); then
  BETA_ITEM="$NEW_ITEM"
  if [[ -n "$PREV_STABLE" ]]; then
    (( BUILD > PREV_STABLE_BUILD )) || die "this beta (build $BUILD) is not newer than the stable in the previous feed (build $PREV_STABLE_BUILD)"
    STABLE_ITEM="$PREV_STABLE"
  fi
else
  STABLE_ITEM="$NEW_ITEM"
  # The previous beta stays only while it is newer than this stable; otherwise it is dropped.
  if [[ -n "$PREV_BETA" ]] && (( PREV_BETA_BUILD > BUILD )); then
    BETA_ITEM="$PREV_BETA"
  fi
fi

OUT_TMP="$(mktemp "${OUTPUT}.XXXXXX")"
{
  print -r -- '<?xml version="1.0" encoding="utf-8"?>'
  print -r -- '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
  print -r -- '    <channel>'
  print -r -- '        <title>Lintel</title>'
  print -r -- '        <link>https://lintelapp.com</link>'
  print -r -- '        <description>Lintel updates</description>'
  print -r -- '        <language>en</language>'
  [[ -z "$STABLE_ITEM" ]] || print -r -- "$STABLE_ITEM"
  [[ -z "$BETA_ITEM" ]] || print -r -- "$BETA_ITEM"
  print -r -- '    </channel>'
  print -r -- '</rss>'
} > "$OUT_TMP"
if ! xmllint --noout "$OUT_TMP" 2>/dev/null; then
  rm -f "$OUT_TMP"
  die "the feed it produced is not well-formed (a bug)"
fi
mv "$OUT_TMP" "$OUTPUT"
print -r -- "Wrote $OUTPUT: $(grep -c '^        <item>$' "$OUTPUT") item(s) for $VERSION (build $BUILD)."
