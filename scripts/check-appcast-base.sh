#!/bin/bash
# The `publish` guard: fails when the feed built in `sign` was not built on the release that is now the newest one
# with an appcast.xml (another release was published while this run waited in the queue; publishing this feed would
# drop that release's item).
#
# Usage: GITHUB_REPOSITORY=owner/name GH_TOKEN=... scripts/check-appcast-base.sh <previous-tag.txt> <current-tag>
# Fails too when `gh` fails (scripts/previous-release.sh), so an API error cannot pass the guard.
set -euo pipefail
FILE="${1:-}"
TAG="${2:-}"
[[ -f "$FILE" && -n "$TAG" ]] || { echo "usage: check-appcast-base.sh <previous-tag.txt> <current-tag>" >&2; exit 64; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILT_ON="$(tr -d '[:space:]' < "$FILE")"
NOW="$("$HERE/previous-release.sh" "$TAG")"
if [[ "$BUILT_ON" != "$NOW" ]]; then
  echo "::error::appcast.xml was built on release '${BUILT_ON:-none}' but the newest release with a feed is now '${NOW:-none}'. Nothing is published." >&2
  exit 1
fi
echo "The feed was built on the newest release with a feed (${NOW:-none})."
