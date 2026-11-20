#!/bin/zsh
# Designated-requirement logic, in one place so it can be tested without a certificate.
#
# Source it for the functions, or run it:
#   scripts/requirement.sh compare <recorded-file> <actual-file> [--on-placeholder fail|warn]
#       recorded-file is Resources/designated-requirement.txt, actual-file the `codesign -dr -` output.
#       equal -> 0. A placeholder (the file still holds REPLACE-WITH...) -> 1 with fail (default), 0 with warn.
#       different -> 1.
#   scripts/requirement.sh check <actual-file>
#       the requirement names the Team ID of scripts/release-team-id.txt through certificate leaf[subject.OU] and
#       anchor apple generic, and has no cdhash. Prints every problem; 0 when there is none.
# Messages carry the ::error:: / ::warning:: prefix when GITHUB_ACTIONS is set.

_REQ_ROOT="${${(%):-%x}:A:h:h}"

# The one committed place of the expected Team ID (public, not a secret).
release_team_id() { tr -d '[:space:]' < "$_REQ_ROOT/scripts/release-team-id.txt"; }

_req_msg() { # level text
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then print -r -- "::$1::$2"; else print -r -- "$1: $2"; fi
}

# The requirement as one trimmed line: the text after "designated =>" when there is one, whitespace collapsed.
_req_normalize() { print -r -- "$1" | tr '\n' ' ' | sed -E 's/^[[:space:]]*designated[[:space:]]*=>[[:space:]]*//; s/[[:space:]]+/ /g; s/ $//'; }

# Prints placeholder, equal or different. Arguments: recorded-file actual-file.
requirement_status() {
  local recorded actual
  recorded="$(<"$1")"
  actual="$(<"$2")"
  if [[ "$recorded" == *REPLACE-WITH* ]]; then print placeholder; return 0; fi
  if [[ "$(_req_normalize "$recorded")" == "$(_req_normalize "$actual")" ]]; then print equal; else print different; fi
}

# Prints one line per problem; returns 1 when there is any. Arguments: actual-file [team-id].
requirement_problems() {
  local text team="${2:-$(release_team_id)}" bad=0
  text="$(<"$1")"
  if [[ "$text" == *cdhash* ]]; then
    print -r -- "the designated requirement contains a cdhash: the bundle is signed ad-hoc, not with Developer ID"; bad=1
  fi
  if [[ "$text" != *"anchor apple generic"* ]]; then
    print -r -- "the designated requirement lacks 'anchor apple generic'"; bad=1
  fi
  if ! print -r -- "$text" | grep -Eq "certificate leaf\[subject\.OU\] = \"?${team}\"?([[:space:]]|\$)"; then
    print -r -- "the designated requirement does not name Team ID ${team} through 'certificate leaf[subject.OU]'"; bad=1
  fi
  return $bad
}

requirement_cli() {
  case "${1:-}" in
    compare)
      local mode=fail
      [[ "${4:-}" == --on-placeholder ]] && mode="${5:-fail}"
      [[ -f "${2:-}" && -f "${3:-}" ]] || { echo "usage: requirement.sh compare <recorded> <actual> [--on-placeholder fail|warn]" >&2; return 64; }
      case "$(requirement_status "$2" "$3")" in
        equal) echo "The designated requirement equals the recorded one." ;;
        placeholder)
          if [[ "$mode" == warn ]]; then
            _req_msg warning "Resources/designated-requirement.txt still holds the placeholder, so the requirement is not compared. Record the printed requirement (Step 3.4)."
          else
            _req_msg error "Resources/designated-requirement.txt still holds the placeholder: record the Developer ID requirement (Step 3.4) before releasing."
            return 1
          fi ;;
        different)
          _req_msg error "The designated requirement differs from Resources/designated-requirement.txt. Users would lose their TCC grants (BACKWARD_COMPATIBILITY.md section 4)."
          diff -u "$2" "$3" || true
          return 1 ;;
      esac ;;
    check)
      [[ -f "${2:-}" ]] || { echo "usage: requirement.sh check <actual>" >&2; return 64; }
      local problems
      if ! problems="$(requirement_problems "$2")"; then
        print -r -- "$problems" | while IFS= read -r line; do _req_msg error "$line"; done
        return 1
      fi ;;
    *) echo "usage: requirement.sh compare|check ..." >&2; return 64 ;;
  esac
}

if [[ "${ZSH_EVAL_CONTEXT:-}" != *:file* ]]; then
  set -uo pipefail
  requirement_cli "$@"
fi
