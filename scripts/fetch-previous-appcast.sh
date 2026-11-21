#!/bin/bash
# Fetches the previous release's appcast.xml for the feed build (the release workflow, `sign` job).
#
# Usage: GITHUB_REPOSITORY=owner/name GH_TOKEN=... scripts/fetch-previous-appcast.sh <out-dir> <tag-or-empty>
#   <tag-or-empty>  the tag being released; empty for a run that is not a tag (nothing is fetched: such a run builds
#                   a feed with no previous one and publishes nothing)
# Writes <out-dir>/previous-tag.txt (the release the feed is built on, empty for none) and, when that release has one,
# <out-dir>/previous/appcast.xml. The file is only data here: scripts/release-appcast.sh refuses it unless its
# signature verifies.
#
# Fails (non-zero) when the releases API call fails (a 5xx or a rate limit must not look like "no previous release":
# the other channel's item would be dropped) and when the download fails. "No previous release" is an answer only
# when `gh` succeeded and listed none. The release is chosen by scripts/previous-release.sh, which only considers
# releases that have an appcast.xml (the rule the site uses, spec D17).
# Plain bash: it runs in the `sign` job next to the other scripts and needs only `gh`.
set -euo pipefail
OUT="${1:-}"
TAG="${2-}"
[[ -n "$OUT" && $# -eq 2 ]] || { echo "usage: fetch-previous-appcast.sh <out-dir> <tag-or-empty>" >&2; exit 64; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT"
: > "$OUT/previous-tag.txt"
if [[ -z "$TAG" ]]; then
  echo "Not a tag run: no previous feed is fetched."
  exit 0
fi
PREVIOUS_TAG="$("$HERE/previous-release.sh" "$TAG")"
if [[ -z "$PREVIOUS_TAG" ]]; then
  echo "No earlier release has an appcast.xml: the feed starts here."
  exit 0
fi
rm -rf "$OUT/previous"
mkdir -p "$OUT/previous"
gh release download "$PREVIOUS_TAG" --repo "$GITHUB_REPOSITORY" --pattern appcast.xml --dir "$OUT/previous"
[[ -s "$OUT/previous/appcast.xml" ]] || { echo "::error::The download of appcast.xml from $PREVIOUS_TAG left no file." >&2; exit 1; }
printf '%s\n' "$PREVIOUS_TAG" > "$OUT/previous-tag.txt"
echo "The feed is built on release $PREVIOUS_TAG."
