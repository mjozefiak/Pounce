#!/bin/bash
# Runs a command under a wall-clock limit and diagnoses a hang instead of letting CI sit until the
# job timeout.
#
#   scripts/test-with-watchdog.sh [--limit <seconds>] [--name <label>] -- <command...>
#
# The command's output goes to stdout and, as a copy, to a file in the watchdog directory
# ($RUNNER_TEMP/test-watchdog, else $TMPDIR/test-watchdog). The command's exit code is passed on.
# When the limit passes the script
#   1. runs `sample <pid> 10` on every swiftpm-testing-helper / xctest in the command's process tree
#      (<dir>/<label>-<pid>-sample.txt),
#   2. writes the names (never the output) of tests that started and did not finish to
#      <dir>/<label>-unfinished-tests.txt,
#   3. kills the whole tree (TERM, then KILL after 5 s),
#   4. prints `::error::<label> exceeded <N> s; samples in <dir>`, then `watchdog-dir=<dir>` as the
#      last stdout line (and `dir=<dir>` to $GITHUB_OUTPUT when set), and exits 124.
# The copy of the output is deleted before the script ends, so the directory holds no test output.
# Only bash, ps, sample and kill are needed.

set -u
set -m # every background job gets its own process group

limit=1200
name=test
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) limit="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) echo "test-with-watchdog: unknown option '$1'" >&2; exit 2 ;;
  esac
done
case "$limit" in '' | *[!0-9]* | 0) echo "test-with-watchdog: --limit must be a positive number of seconds" >&2; exit 2 ;; esac
[ $# -gt 0 ] || { echo "test-with-watchdog: usage: $0 [--limit <seconds>] [--name <label>] -- <command...>" >&2; exit 2; }
label=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')

root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
dir="${root%/}/test-watchdog"
mkdir -p "$dir"
log="$dir/$label-$$-output.log"

# Prints the pids below $1 (children, grandchildren, ...), one per line.
descendants() {
  ps -axo pid=,ppid= | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      n = 1; queue[1] = root
      for (i = 1; i <= n; i++) {
        m = split(kids[queue[i]], c, " ")
        for (j = 1; j <= m; j++) { queue[++n] = c[j]; print c[j] }
      }
    }'
}

alive() { kill -0 "$1" 2>/dev/null; }

# Lists tests that have a "started" line and no matching "passed/failed/skipped" line.
unfinished_tests() {
  awk '
    function name_between(s, start_re, end_re,   a, b) {
      if (!match(s, start_re)) return ""
      a = substr(s, RSTART + RLENGTH)
      if (!match(a, end_re)) return ""
      return substr(a, 1, RSTART - 1)
    }
    /^[^A-Za-z]*Test Case .* started\.$/ || /^[^A-Za-z]*Test .* started\.$/ {
      n = name_between($0, "Test (Case )?", " started\\.$")
      if (n != "" && !(n in seen)) { seen[n] = 1; order[++count] = n }
      next
    }
    /^[^A-Za-z]*Test (Case )?.* (passed|failed|skipped|recorded)/ {
      n = name_between($0, "Test (Case )?", " (passed|failed|skipped|recorded)")
      if (n != "") done[n] = 1
    }
    END { for (i = 1; i <= count; i++) if (!(order[i] in done)) print order[i] }
  ' "$1"
}

timed_out=0
interrupted=0
trap 'timed_out=1' USR1
trap 'interrupted=1' INT TERM

( set -o pipefail; "$@" 2>&1 | tee "$log" ) &
cmd=$!

# The timer sleeps in the background and signals this script, which is blocked in `wait`.
(
  sleep "$limit" &
  s=$!
  trap 'kill "$s" 2>/dev/null; exit 0' TERM
  wait "$s" && kill -USR1 $$
) &
timer=$!
# `$$` inside the subshell is still this script's pid, which is what the timer must signal.

rc=0
while :; do
  wait "$cmd"
  rc=$?
  if [ "$timed_out" = 1 ] || [ "$interrupted" = 1 ]; then break; fi
  alive "$cmd" || break # wait was interrupted by some other signal; otherwise the command is done
done

if [ "$timed_out" = 0 ] && [ "$interrupted" = 0 ]; then
  kill "$timer" 2>/dev/null
  wait "$timer" 2>/dev/null
  rm -f "$log"
  exit "$rc"
fi

kill "$timer" 2>/dev/null
tree="$cmd $(descendants "$cmd" | tr '\n' ' ')"

if [ "$timed_out" = 1 ]; then
  # A hang: collect the evidence before anything dies.
  sampled=""
  for p in $tree; do
    base=$(ps -o comm= -p "$p" 2>/dev/null | awk -F/ '{print $NF}')
    case "$base" in
      swiftpm-testing-helper | xctest | *xctest*)
        sample "$p" 10 -file "$dir/$label-$p-sample.txt" >/dev/null 2>&1 &
        sampled="$sampled $!"
        ;;
    esac
  done
  [ -f "$log" ] && unfinished_tests "$log" >"$dir/$label-unfinished-tests.txt"
  for s in $sampled; do wait "$s" 2>/dev/null; done
fi

# Kill the whole tree: TERM now, KILL for what is left after 5 s.
{ # job-control messages about the killed jobs are noise
for p in $tree; do kill -TERM "$p" 2>/dev/null; done
kill -TERM -- "-$cmd" 2>/dev/null
( sleep 5 & k=$!; trap 'kill "$k" 2>/dev/null; exit 0' TERM; wait "$k" &&
  { for p in $tree; do kill -KILL "$p" 2>/dev/null; done; kill -KILL -- "-$cmd" 2>/dev/null; } ) &
grace=$!
wait "$cmd" 2>/dev/null
kill "$grace"; wait "$grace"
for p in $tree; do alive "$p" && kill -KILL "$p" 2>/dev/null; done
} 2>/dev/null
rm -f "$log"

if [ "$interrupted" = 1 ] && [ "$timed_out" = 0 ]; then
  echo "test-with-watchdog: $label interrupted; process tree killed" >&2
  exit 143
fi

echo "::error::$label exceeded $limit s; samples in $dir"
if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "dir=$dir" >>"$GITHUB_OUTPUT"; fi
echo "watchdog-dir=$dir"
exit 124
