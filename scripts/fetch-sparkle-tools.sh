#!/bin/zsh
# Downloads Sparkle's release zip, checks it against the SHA-256 committed in scripts/sparkle-tools.txt and extracts
# bin/sign_update into <dir>. Prints the path of sign_update. Nothing is run from the download before the check passes.
# The release `sign` job uses this instead of resolving the package graph: it needs one binary, not the app's dependencies.
#
# Usage: scripts/fetch-sparkle-tools.sh <dir> [<zip>]   (<zip>: use this local file instead of downloading; tests)
#   SPARKLE_TOOLS_CONF  another config file in place of scripts/sparkle-tools.txt (tests only)
# Fails (non-zero) when the zip does not match the checksum, and then nothing from it is extracted.
set -euo pipefail
DIR="${1:-}"
[[ -n "$DIR" ]] || { print -u2 "usage: fetch-sparkle-tools.sh <dir> [<zip>]"; exit 64; }
CONF="${SPARKLE_TOOLS_CONF:-${0:A:h}/sparkle-tools.txt}"
VERSION="$(sed -n 's/^VERSION=//p' "$CONF")"
WANT="$(sed -n 's/^SHA256=//p' "$CONF")"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' && "$WANT" =~ '^[0-9a-f]{64}$' ]] || { print -u2 "fetch-sparkle-tools.sh: $CONF is malformed"; exit 1; }
mkdir -p "$DIR"
ZIP="${2:-}"
if [[ -z "$ZIP" ]]; then
  ZIP="$DIR/sparkle.zip"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$ZIP" \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-for-Swift-Package-Manager.zip"
fi
GOT="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
if [[ "$GOT" != "$WANT" ]]; then
  print -u2 "::error::The Sparkle $VERSION download does not match the SHA-256 in scripts/sparkle-tools.txt (got $GOT)."
  exit 1
fi
unzip -q -o -j "$ZIP" bin/sign_update -d "$DIR/bin"
chmod 755 "$DIR/bin/sign_update"
print -r -- "$DIR/bin/sign_update"
