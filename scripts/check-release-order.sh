#!/bin/bash
# A release tag must point at a STRICT descendant of the commit of the most recently published release, so that build
# numbers (the commit count) and publication order cannot disagree.
#
# Usage: scripts/check-release-order.sh <candidate-commit> [<previous-release-commit>]
#   no previous release (argument missing or empty)  -> passes
#   candidate is a strict descendant of previous     -> passes
#   same commit, an ancestor, or unrelated history   -> fails (exit 1)
#   previous commit unknown to this clone            -> fails (the checkout must be complete: fetch-depth 0)
#
# Usage (the release workflow): scripts/check-release-order.sh --github <candidate-commit> <current-tag>
#   Finds the previous release itself: the most recently published (by published_at) non-draft release of
#   $GITHUB_REPOSITORY other than <current-tag>, pre-releases included, reading every page of the releases API through
#   `gh` (GH_TOKEN), and checks against the commit of its tag. A tag missing from the clone fails.
# The workflow runs it twice, both times inside the `release-tags` concurrency group: first in `sign`, before any secret
# is used, and again in `publish` right before the release is created, when every earlier release has been published.
# Plain bash (not zsh like the other scripts): `publish` runs on ubuntu-latest, where zsh is not guaranteed.
set -euo pipefail

# Prints "published_at<TAB>tag_name" for every published (non-draft) release.
RELEASES_JQ='.[] | select(.draft == false and .published_at != null) | [.published_at, .tag_name] | @tsv'

if [[ "${1:-}" == --github ]]; then
  [[ -n "${2:-}" && -n "${3:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || {
    echo "usage: GITHUB_REPOSITORY=owner/name check-release-order.sh --github <candidate-commit> <current-tag>" >&2
    exit 64
  }
  CURRENT_TAG="$3"
  RELEASES="$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" --jq "$RELEASES_JQ")"
  # ISO-8601 UTC timestamps sort as text; the tag is compared as a whole field, never as a pattern.
  PREVIOUS_TAG="$(printf '%s\n' "$RELEASES" | awk -F'\t' -v tag="$CURRENT_TAG" 'NF == 2 && $2 != tag' | sort | tail -n 1 | cut -f2)"
  PREVIOUS_COMMIT=""
  if [[ -n "$PREVIOUS_TAG" ]]; then
    PREVIOUS_COMMIT="$(git rev-parse --verify --quiet "refs/tags/$PREVIOUS_TAG^{commit}")" || {
      echo "::error::The newest release is $PREVIOUS_TAG but that tag is not in this clone." >&2
      exit 1
    }
    echo "Newest published release: $PREVIOUS_TAG"
  fi
  set -- "$2" "$PREVIOUS_COMMIT"
fi

CANDIDATE="${1:-}"
PREVIOUS="${2:-}"
[[ -n "$CANDIDATE" ]] || { echo "usage: check-release-order.sh <candidate-commit> [<previous-release-commit>]" >&2; exit 64; }
CANDIDATE="$(git rev-parse --verify --quiet "$CANDIDATE^{commit}")" || { echo "::error::Unknown commit: $1" >&2; exit 64; }

if [[ -z "$PREVIOUS" ]]; then
  echo "No published release yet: the order check passes."
  exit 0
fi
PREVIOUS="$(git rev-parse --verify --quiet "$PREVIOUS^{commit}")" || {
  echo "::error::The commit of the newest release is not in this clone, so the order cannot be checked." >&2
  exit 1
}
if [[ "$CANDIDATE" == "$PREVIOUS" ]]; then
  echo "::error::The tagged commit is the commit of the newest release: a release needs new commits." >&2
  exit 1
fi
if git merge-base --is-ancestor "$PREVIOUS" "$CANDIDATE"; then
  echo "The tagged commit is a strict descendant of the newest release's commit."
  exit 0
fi
echo "::error::The tagged commit is not a descendant of the newest release's commit. Build numbers and publication order would disagree; tag a newer commit of main." >&2
exit 1
