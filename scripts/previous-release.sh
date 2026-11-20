#!/bin/bash
# Prints the tag of the previous release: the most recently published (by published_at) non-draft release of
# $GITHUB_REPOSITORY other than <current-tag>, pre-releases included; prints nothing when there is none. Reads every
# page of the releases API through `gh` (GH_TOKEN). The same rule scripts/check-release-order.sh --github uses.
#
# Usage: GITHUB_REPOSITORY=owner/name scripts/previous-release.sh <current-tag>
# The release workflow runs it in `sign` (to download that release's appcast.xml) and again in `publish`: if the answer
# changed in between, another release was published meanwhile and the feed built in `sign` lacks its item.
# Plain bash: `publish` runs on ubuntu-latest.
set -euo pipefail
CURRENT_TAG="${1:-}"
[[ -n "$CURRENT_TAG" && -n "${GITHUB_REPOSITORY:-}" ]] || {
  echo "usage: GITHUB_REPOSITORY=owner/name previous-release.sh <current-tag>" >&2
  exit 64
}
RELEASES="$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
  --jq '.[] | select(.draft == false and .published_at != null) | [.published_at, .tag_name] | @tsv')"
printf '%s\n' "$RELEASES" | awk -F'\t' -v tag="$CURRENT_TAG" 'NF == 2 && $2 != tag' | sort | tail -n 1 | cut -f2
