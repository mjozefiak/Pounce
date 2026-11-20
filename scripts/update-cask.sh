#!/bin/zsh
# Usage: scripts/update-cask.sh <version> <sha256> [output-directory]
# Renders the Homebrew casks from packaging/homebrew/*.rb.tmpl (spec 2026-11-19, Phase 5, Step 5.1):
#   Casks/lintel@beta.rb for every release, Casks/lintel.rb only for a stable one (no -beta.N).
# <version> is the tag without "v" (the CFBundleShortVersionString), <sha256> the 64 hex digits of the DMG.
# A file that already has the rendered content is not touched. Exit 64 on bad input, nothing written.
# Not wired into the release workflow yet.
set -euo pipefail

version="${1:-}"
sha="${2:-}"
out="${3:-Casks}"
if (( $# < 2 || $# > 3 )); then
  echo "Usage: update-cask.sh <version> <sha256> [output-directory]" >&2
  exit 64
fi
if [[ ! "$version" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$' ]]; then
  echo "Not a version: '${version}'. Expected X.Y.Z or X.Y.Z-beta.N (no leading v, no leading zeros, N >= 1)." >&2
  exit 64
fi
prerelease="${match[4]:-}"
if [[ ! "$sha" =~ '^[0-9a-f]{64}$' ]]; then
  echo "Not a SHA-256: expected 64 lowercase hex digits." >&2
  exit 64
fi

tmpl="${0:A:h:h}/packaging/homebrew"
mkdir -p "$out"
render() {
  local name="$1" file="$out/$1.rb" new
  new="$(mktemp)"
  sed -e "s/@VERSION@/$version/" -e "s/@SHA256@/$sha/" "$tmpl/$name.rb.tmpl" > "$new"
  if [[ -f "$file" ]] && cmp -s "$new" "$file"; then
    echo "unchanged $file"
  else
    cat "$new" > "$file"
    echo "wrote $file"
  fi
  rm -f "$new"
}
render "lintel@beta"
[[ -z "$prerelease" ]] && render lintel
exit 0
