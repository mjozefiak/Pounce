#!/bin/bash
# Prints the tag of the release the update feed is built on: the most recently published (by published_at) non-draft
# release of $GITHUB_REPOSITORY other than <current-tag> that HAS an `appcast.xml` asset, pre-releases included; prints
# nothing when there is none. This is the release the site serves /appcast.xml from (spec decision D17), so a release
# without the asset is skipped here as it is there. Reads every page of the releases API through `gh` (GH_TOKEN) and
# fails (non-zero, nothing printed) when `gh` fails, so an API error can never look like "no previous release".
#
# Usage: GITHUB_REPOSITORY=owner/name scripts/previous-release.sh <current-tag>
# The release workflow runs it in `sign` (scripts/fetch-previous-appcast.sh) and again in `publish`
# (scripts/check-appcast-base.sh): if the answer changed in between, another release with a feed was published
# meanwhile and the feed built in `sign` lacks its item. (scripts/check-release-order.sh uses the same listing without
# the asset condition: the order of releases does not depend on feeds.)
# Plain bash: `publish` runs on ubuntu-latest.
set -euo pipefail
CURRENT_TAG="${1:-}"
[[ -n "$CURRENT_TAG" && -n "${GITHUB_REPOSITORY:-}" ]] || {
  echo "usage: GITHUB_REPOSITORY=owner/name previous-release.sh <current-tag>" >&2
  exit 64
}
RELEASES="$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
  --jq '.[] | select(.draft == false and .published_at != null and any(.assets[]?; .name == "appcast.xml")) | [.published_at, .tag_name] | @tsv')"
printf '%s\n' "$RELEASES" | awk -F'\t' -v tag="$CURRENT_TAG" 'NF == 2 && $2 != tag' | sort | tail -n 1 | cut -f2
