#!/bin/zsh
# Usage: scripts/version-from-tag.sh [--is-prerelease] <tag>
# The only place that knows the tag grammar (BACKWARD_COMPATIBILITY.md section 6):
#   v<major>.<minor>.<patch>            a release          (v0.1.0)
#   v<major>.<minor>.<patch>-beta.<N>   a pre-release      (v0.1.0-beta.1)
# with no leading zeros in any number and N >= 1. Anything else (v0.1, v0.1.0-rc.1, v01.0.0, 0.1.0, empty) exits 64
# with a message on stderr and prints nothing on stdout.
# Without a flag it prints the version without the leading "v"; with --is-prerelease it prints "true" or "false".
set -euo pipefail

want_prerelease=0
if [[ "${1:-}" == --is-prerelease ]]; then
  want_prerelease=1
  shift
fi
tag="${1:-}"
if (( $# > 1 )) || [[ ! "$tag" =~ '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$' ]]; then
  echo "Not a release tag: '${tag}'. Expected vX.Y.Z or vX.Y.Z-beta.N (no leading zeros, N >= 1)." >&2
  exit 64
fi
if (( want_prerelease )); then
  [[ -n "${match[4]:-}" ]] && print true || print false
else
  print -r -- "${tag#v}"
fi
