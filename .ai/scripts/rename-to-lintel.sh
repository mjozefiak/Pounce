#!/usr/bin/env bash
# Rename Pounce -> Lintel across a checkout. Idempotent: a tree that is already renamed produces no changes.
#
#   .ai/scripts/rename-to-lintel.sh            dry run: lists what would change
#   .ai/scripts/rename-to-lintel.sh --apply    rewrites text files, then renames paths with git mv
#
# Re-run it after rebasing a branch that was written against the old names (for example the meetings plugin).
#
# What is renamed:   Pounce* / pounce* identifiers, module and directory names, app.pounce.Pounce (bundle id) ->
#                    com.lintelapp.Lintel, every other app.pounce.* (Keychain services, logger and queue labels, QA
#                    flags) -> com.lintelapp.*, POUNCE_* environment variables.
# What is protected: github.com/mjozefiak/Pounce and mjozefiak.github.io/Pounce (the repository keeps its name), the
#                    historical spec file name pounce-launcher-mvp, any line that carries the marker LEGACY-POUNCE
#                    (the one-time migrations must keep the old names), and these paths: .ai/specs, .ai/runs,
#                    .ai/prototypes, .ai/analysis, .ai/qa, .ai/tmp, Packages, .claude, .uxproof, skills-lock.json.
set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

cd "$(git rev-parse --show-toplevel)"

EXCLUDE=(
  ':!.ai/specs' ':!.ai/runs' ':!.ai/prototypes' ':!.ai/analysis' ':!.ai/qa' ':!.ai/tmp'
  ':!Packages' ':!.claude' ':!.uxproof' ':!skills-lock.json' ':!.ai/scripts/rename-to-lintel.sh'
)

# 1. Text files that mention the old name (binary files are skipped by -I).
FILES=$(git grep -lIi 'pounce' -- . "${EXCLUDE[@]}" || true)
COUNT=$(printf '%s\n' "$FILES" | grep -c . || true)

if [ "$APPLY" = "0" ]; then
  echo "dry run: $COUNT text files mention Pounce"
  printf '%s\n' "$FILES" | head -200
  echo "paths that would be renamed:"
  git ls-files -- . "${EXCLUDE[@]}" | grep -E 'Pounce|pounce' | grep -v 'pounce-launcher-mvp' | head -200 || true
  exit 0
fi

# 2. Rewrite contents. Lines marked LEGACY-POUNCE are left alone.
for f in $FILES; do
  perl -pi -e '
    unless (/LEGACY-POUNCE/) {
      s{mjozefiak/Pounce}{mjozefiak/\@\@KEEP1\@\@}g;
      s{github\.io/Pounce}{github.io/\@\@KEEP2\@\@}g;
      s{pounce-launcher-mvp}{\@\@KEEP3\@\@}g;
      s{app\.pounce\.Pounce}{com.lintelapp.Lintel}g;
      s{app\.pounce}{com.lintelapp}g;
      s{POUNCE}{LINTEL}g;
      s{Pounce}{Lintel}g;
      s{pounce}{lintel}g;
      s{\@\@KEEP1\@\@}{Pounce}g;
      s{\@\@KEEP2\@\@}{Pounce}g;
      s{\@\@KEEP3\@\@}{pounce-launcher-mvp}g;
    }
  ' "$f"
done

# 3. Rename directories first (Sources/PounceX, Tests/PounceXTests), then the remaining files.
for d in $(git ls-files -- Sources Tests | grep -oE '^(Sources|Tests)/Pounce[A-Za-z]*' | sort -u); do
  git mv "$d" "$(printf '%s' "$d" | sed 's/Pounce/Lintel/')"
done
git ls-files -- . "${EXCLUDE[@]}" | grep -E 'Pounce|pounce' | grep -v 'pounce-launcher-mvp' | while read -r p; do
  new=$(printf '%s' "$p" | sed 's/Pounce/Lintel/g; s/pounce/lintel/g')
  mkdir -p "$(dirname "$new")"
  git mv "$p" "$new"
done

echo "renamed contents of $COUNT files and their paths"
