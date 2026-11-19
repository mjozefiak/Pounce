#!/bin/bash
# Runs a command under a wall-clock limit and diagnoses a hang instead of letting CI sit until the
# job timeout.
#
#   scripts/test-with-watchdog.sh [--limit <seconds>] [--name <label>] -- <command...>
#
# The command runs under a pseudo-terminal (`script`), so swift test writes its test lines as it goes
# instead of holding them in a pipe buffer. Its output goes to stdout and, as a copy, to a private
# temporary file OUTSIDE the watchdog directory (TERM=dumb keeps progress bars out of it). The
# command's exit code is passed on; a command killed by a signal gives the signal NUMBER (e.g. 9),
# not 128+N, because that is what `script` reports.
# Watchdog directory: $RUNNER_TEMP/test-watchdog, else $TMPDIR/test-watchdog.
# When the limit passes the script
#   1. runs `sample <pid> 10` on every swiftpm-testing-helper / xctest in the command's process tree
#      (<dir>/<label>-<pid>-sample.txt),
#   2. writes the names (never the output) of tests that started and did not finish to
#      <dir>/<label>-unfinished-tests.txt,
#   3. kills the whole tree (TERM, then KILL after 5 s),
#   4. prints `::error::<label> exceeded <N> s; samples in <dir>`, then `watchdog-dir=<dir>` as the
#      last stdout line (and `dir=<dir>` to $GITHUB_OUTPUT when set), and exits 124.
# The copy of the output is always removed (also on TERM/INT), and the watchdog directory never holds
# test output, only test names and stack samples.
# Only bash, ps, sample and kill are needed.

set -u
set -m # every background job gets its own process group

limit=1200
name=test
while [ $# -gt 0 ]; do
  case "$1" in
    --limit | --name)
      [ $# -ge 2 ] || { echo "test-with-watchdog: $1 needs a value" >&2; exit 2; }
      if [ "$1" = --limit ]; then limit="$2"; else name="$2"; fi
      shift 2
      ;;
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
logdir=$(mktemp -d "${TMPDIR:-/tmp}/test-watchdog-log.XXXXXX") || exit 2
log="$logdir/output.log"
trap 'rm -rf "$logdir"' EXIT

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

# Lists the NAMES of tests that have a "started" line and no "passed/failed/skipped" line. Lines of
# parameterized test cases ("Test case passing ... argument") and "recorded an issue" lines are
# ignored, so neither argument values nor issue text ever reach the list.
unfinished_tests() {
  # The pty makes swift test colour its output, so the ANSI escapes are removed first.
  tr -d '\r' <"$1" | sed -e "s/$(printf '\033')\\[[0-9;]*[A-Za-z]//g" | awk '
    function name_between(s, end_re,   a) {
      if (!match(s, /Test (Case )?/)) return ""
      a = substr(s, RSTART + RLENGTH)
      if (!match(a, end_re)) return ""
      a = substr(a, 1, RSTART - 1)
      if (match(a, / → /)) a = substr(a, 1, RSTART - 1)
      return a
    }
    /^[^A-Za-z]*Test case passing / { next }
    / recorded an issue/ { next }
    /^[^A-Za-z]*Test (Case )?.* started\.$/ {
      n = name_between($0, " started\\.$")
      if (n != "" && n != "run" && !(n in seen)) { seen[n] = 1; order[++count] = n }
      next
    }
    /^[^A-Za-z]*Test (Case )?.* (passed|failed) (after|\()/ || /^[^A-Za-z]*Test (Case )?.* skipped/ {
      n = name_between($0, " (passed|failed) (after|\\()| skipped")
      if (n != "") done[n] = 1
    }
    END { for (i = 1; i <= count; i++) if (!(order[i] in done)) print order[i] }
  '
}

timed_out=0
interrupted=0
trap 'timed_out=1' USR1
trap 'interrupted=1' INT TERM

# `script` gives the command a pty (line-buffered output); `sed -l` strips the CR the pty adds and the
# "^D" it echoes when stdin (/dev/null) ends, without buffering.
BS=$(printf '\b'); CR=$(printf '\r')
( set -o pipefail
  TERM=dumb script -q /dev/null "$@" </dev/null 2>&1 |
    sed -l -e "1s/^^D$BS$BS//" -e "s/$CR\$//" | tee "$log" ) &
cmd=$!

# The timer sleeps in the background and signals this script, which is blocked in `wait`.
(
  sleep "$limit" &
  s=$!
  trap 'kill "$s" 2>/dev/null; exit 0' TERM
  wait "$s" && kill -USR1 $$
) >/dev/null 2>&1 &
timer=$!
# `$$` inside the subshell is still this script's pid, which is what the timer must signal.

rc=0
while :; do
  wait "$cmd"
  rc=$?
  if [ "$timed_out" = 1 ] && ! alive "$cmd"; then
    # The command finished at the same moment as the limit: that is not a hang.
    timed_out=0
    wait "$cmd"
    rc=$?
    break
  fi
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
  # Each sample takes 10 s; give them 30 s in all, then move on to the kill.
  ( sleep 30 & w=$!; trap 'kill "$w" 2>/dev/null; exit 0' TERM
    wait "$w" && { for s in $sampled; do kill "$s" 2>/dev/null; done; } ) >/dev/null 2>&1 &
  sample_guard=$!
  for s in $sampled; do wait "$s" 2>/dev/null; done
  kill "$sample_guard" 2>/dev/null; wait "$sample_guard" 2>/dev/null
fi

# Kill the whole tree: TERM now, KILL for what is left after 5 s.
{ # job-control messages about the killed jobs are noise
for p in $tree; do kill -TERM "$p" 2>/dev/null; done
kill -TERM -- "-$cmd" 2>/dev/null
( sleep 5 & k=$!; trap 'kill "$k" 2>/dev/null; exit 0' TERM; wait "$k" &&
  { for p in $tree; do kill -KILL "$p" 2>/dev/null; done; kill -KILL -- "-$cmd" 2>/dev/null; } ) >/dev/null 2>&1 &
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
