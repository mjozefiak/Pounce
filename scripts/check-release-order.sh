#!/bin/zsh
# A release tag must point at a STRICT descendant of the commit of the most recently published release, so that build
# numbers (the commit count) and publication order cannot disagree.
#
# Usage: scripts/check-release-order.sh <candidate-commit> [<previous-release-commit>]
#   no previous release (argument missing or empty)  -> passes
#   candidate is a strict descendant of previous     -> passes
#   same commit, an ancestor, or unrelated history   -> fails (exit 1)
#   previous commit unknown to this clone            -> fails (the checkout must be complete: fetch-depth 0)
# Run it inside the repository (the release workflow's `sign` job, before any secret is used).
set -euo pipefail

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
