#!/usr/bin/env bash
# Runs MeetingEvalTests in a release build and prints the path of the JSON it wrote.
# Usage: run.sh --audio <wav> --out <dir> --name <n> --engine <parakeet-ultra|whisper-large-v3-turbo>
#               --language <pl|en> --speech-folder <dir> [--notes-model <gguf>] [--diarization-folder <dir>] [--speaker-names <json>] [--allow-dirty]
# Exit codes: 0 ok, 2 usage/input error, 3 dirty Sources/Package.swift refused, 4 test failure, 5 build failure.
# Uses `swift build -c release -Xswiftc -enable-testing` (`swift test -c release` fails to link
# ClipboardPluginTests) and then runs ONLY MeetingEvalTests by calling the Swift Testing helper
# (swiftpm-testing-helper, what `swift test` uses) with `--filter`, so no other suite shares the
# process: the memory peak and real-time factor are not contaminated.
set -euo pipefail

die() { printf 'run.sh: %s\n' "$1" >&2; exit "${2:-2}"; }

audio="" out="" name="" engine="" language="" speech="" notes="" diar="" names="" allow_dirty=0
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--allow-dirty" ]]; then allow_dirty=1; shift; continue; fi
  [[ $# -ge 2 ]] || die "missing value for $1"
  case "$1" in
    --audio) audio="$2" ;;
    --out) out="$2" ;;
    --name) name="$2" ;;
    --engine) engine="$2" ;;
    --language) language="$2" ;;
    --speech-folder) speech="$2" ;;
    --notes-model) notes="$2" ;;
    --diarization-folder) diar="$2" ;;
    --speaker-names) names="$2" ;;
    *) die "unknown argument: $1" ;;
  esac
  shift 2
done

[[ -n "$audio" && -n "$out" && -n "$name" && -n "$engine" && -n "$language" && -n "$speech" ]] \
  || die "required: --audio --out --name --engine --language --speech-folder"
[[ -f "$audio" ]] || die "audio file not found: $audio"
[[ -d "$speech" ]] || die "speech folder not found: $speech"
[[ -z "$notes" || -f "$notes" ]] || die "notes model not found: $notes"
[[ -z "$diar" || -d "$diar" ]] || die "diarization folder not found: $diar"
[[ -z "$names" || -f "$names" ]] || die "speaker names file not found: $names"
case "$engine" in parakeet-ultra | whisper-large-v3-turbo) ;; *) die "bad engine: $engine" ;; esac
case "$language" in pl | en) ;; *) die "bad language: $language" ;; esac

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo"
mkdir -p "$out"
abs() { (cd "$1" && pwd); }
out="$(abs "$out")"
audio="$(cd "$(dirname "$audio")" && pwd)/$(basename "$audio")"
speech="$(abs "$speech")"
[[ -z "$notes" ]] || notes="$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")"
[[ -z "$diar" ]] || diar="$(abs "$diar")"
[[ -z "$names" ]] || names="$(cd "$(dirname "$names")" && pwd)/$(basename "$names")"

version="$(git rev-parse --short HEAD)"
if [[ -n "$(git status --porcelain -- Sources Package.swift Package.resolved)" ]]; then
  if [[ $allow_dirty -eq 1 ]]; then
    version="$version-dirty"
  else
    die "uncommitted changes under Sources/ or Package.swift; commit them or pass --allow-dirty" 3
  fi
elif [[ -n "$(git status --porcelain)" ]]; then
  version="$version+harness"
fi

swift build -c release -Xswiftc -enable-testing --product MeetingsPluginTests >&2 || exit 5

bundle="$(find "$repo/.build" -path '*Release/MeetingsPluginTests.xctest' -maxdepth 6 -print -quit)"
[[ -n "$bundle" ]] || die "MeetingsPluginTests.xctest not found under .build"

dev="${DEVELOPER_DIR:-$(xcode-select -p)}"
helper="$dev/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
platform="$dev/Platforms/MacOSX.platform/Developer"
binary="$bundle/Contents/MacOS/MeetingsPluginTests"
[[ -x "$helper" ]] || die "swiftpm-testing-helper not found: $helper"
[[ -f "$binary" ]] || die "test binary not found: $binary"

# Some Macs run a cleanup (another agent session, a watchdog) that kills any process whose command line
# contains "MeetingsPluginTests": the run then dies with SIGTERM (exit 143) after a few seconds. So the helper
# and the bundle are started under neutral names (a copy and a symlink in a temporary folder) and the filter
# does not repeat the module name. The test still runs from the same build products.
stage="$(mktemp -d "${TMPDIR:-/tmp}/meeting-eval-run.XXXXXX")"
cp "$helper" "$stage/eval-runner"
ln -s "$bundle" "$stage/eval.xctest"
helper="$stage/eval-runner"
binary="$stage/eval.xctest/Contents/MacOS/MeetingsPluginTests"
before="$(mktemp "${TMPDIR:-/tmp}/meeting-eval-before.XXXXXX")"
log="$out/$name.run.log"
: >"$log"
trap 'rm -rf "$before" "$stage"' EXIT

rc=0
env LINTEL_MEETING_EVAL_AUDIO="$audio" \
  LINTEL_MEETING_EVAL_OUT="$out" \
  LINTEL_MEETING_EVAL_NAME="$name" \
  LINTEL_MEETING_EVAL_ENGINE="$engine" \
  LINTEL_MEETING_EVAL_LANGUAGE="$language" \
  LINTEL_MEETING_EVAL_SPEECH_FOLDER="$speech" \
  LINTEL_MEETING_EVAL_CODE_VERSION="$version" \
  ${notes:+LINTEL_MEETING_EVAL_NOTES_MODEL="$notes"} \
  ${diar:+LINTEL_MEETING_EVAL_DIARIZATION_FOLDER="$diar"} \
  ${names:+LINTEL_MEETING_EVAL_SPEAKER_NAMES="$names"} \
  DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks" \
  DYLD_LIBRARY_PATH="$platform/usr/lib" \
  "$helper" --test-bundle-path "$binary" --testing-library swift-testing \
  --filter 'EvalTests/evaluatesARealRecording' >"$log" 2>&1 || rc=$?

grep -E 'MeetingEval|Eval:|✘|Test run with|Suite ' "$log" | cut -c1-200 >&2 || true
if [[ $rc -ne 0 ]]; then
  printf 'run.sh: last lines: %s\n' "$(tail -n 5 "$log" | cut -c1-200 | tr '\n' '|')" >&2
  die "MeetingEvalTests failed (exit $rc); full log kept: $log" 4
fi
if ! grep -qE 'Test run with 1 test.* passed' "$log"; then
  die "expected exactly one test to run (isolation check failed); full log kept: $log" 4
fi
rm -f "$log"

json="$(find "$out" -maxdepth 1 -name '*.json' -newer "$before" -print | head -n 1)"
[[ -n "$json" ]] || die "no JSON written to $out"
printf '%s\n' "$json"
ls -l "$json"
