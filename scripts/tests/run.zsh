#!/bin/zsh
# Runs every scripts/tests/test_*.zsh and fails when any of them fails.
set -u
rc=0
for t in ${0:A:h}/test_*.zsh; do
  print -r -- "== ${t:t}"
  zsh "$t" || rc=1
done
exit $rc
