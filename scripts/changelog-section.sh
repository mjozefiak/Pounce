#!/bin/zsh
# Usage: scripts/changelog-section.sh <version>
# Prints the body of the `## [<version>] - <date>` section of CHANGELOG.md (up to the next `## ` heading,
# without the heading and without surrounding blank lines). <version> is X.Y.Z, X.Y.Z-pre.release (for example 0.1.0-beta.1) or the name Unreleased.
# Exits 1 with a message when the section is missing, appears twice, or (for a version) has no content;
# an empty Unreleased section prints nothing and exits 0. Exits 64 when <version> is malformed.
# A heading without a date (`## [1.0.0]`) is accepted here; ChangelogTests require the date in the real file.
#   CHANGELOG   path of the changelog to read (default: CHANGELOG.md at the repository root; used by the tests)
set -euo pipefail

version="${1:-}"
if [[ ! "$version" =~ '^([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?|Unreleased)$' ]]; then
  echo "Usage: changelog-section.sh <X.Y.Z[-pre]|Unreleased>, got: '$version'" >&2
  exit 64
fi
file="${CHANGELOG:-${0:A:h:h}/CHANGELOG.md}"
[[ -f "$file" ]] || { echo "CHANGELOG not found: $file" >&2; exit 1; }

# A heading is `## [<version>]` optionally followed by ` - <date>`.
count="$(awk -v v="$version" '
  { sub(/\r$/, "") }
  index($0, "## [" v "]") == 1 { rest = substr($0, length("## [" v "]") + 1); if (rest == "" || rest ~ /^ - /) n++ }
  END { print n + 0 }' "$file")"
if (( count == 0 )); then
  echo "CHANGELOG.md has no section for $version (expected a heading like '## [$version] - YYYY-MM-DD')" >&2
  exit 1
elif (( count > 1 )); then
  echo "CHANGELOG.md has $count sections for $version; there must be exactly one" >&2
  exit 1
fi

# The last section runs to the end of the file, where Keep a Changelog puts its link-reference
# definitions (`[1.0.0]: https://...`); those trailing lines are not part of the section.
body="$(awk -v v="$version" '
  { sub(/\r$/, "") }
  /^## / {
    if (inside) { closed = 1; exit }
    rest = substr($0, length("## [" v "]") + 1)
    if (index($0, "## [" v "]") == 1 && (rest == "" || rest ~ /^ - /)) { inside = 1; next }
  }
  inside { lines[++n] = $0 }
  END {
    if (!closed) while (n > 0 && (lines[n] !~ /[^[:space:]]/ || lines[n] ~ /^\[[^]]*\]:[ \t]/)) n--
    for (i = 1; i <= n; i++) print lines[i]
  }' "$file")"
# Trim leading and trailing blank lines.
body="$(print -r -- "$body" | awk 'NF { started = 1 } started { lines[++n] = $0 } END { while (n > 0 && lines[n] !~ /[^[:space:]]/) n--; for (i = 1; i <= n; i++) print lines[i] }')"

if [[ -z "$body" && "$version" != Unreleased ]]; then
  echo "The CHANGELOG.md section for $version is empty" >&2
  exit 1
fi
[[ -z "$body" ]] || print -r -- "$body"
