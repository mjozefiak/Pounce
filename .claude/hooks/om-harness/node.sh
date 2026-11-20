#!/usr/bin/env bash
# Shared by the om-harness hook entrypoints. Claude Code runs hooks in a non-interactive shell, so a Node that
# nvm, Volta or a manual install put on the PATH only for login shells is not found by `exec node`. This file
# finds one, and when there is none it still enforces the markers the guard checks, so a missing Node never
# turns a staged-only run or frozen tests into "allowed".

# Prints the path of a usable node, or nothing.
om_harness_node() {
  local candidate directory nvm_dir default_version
  if [[ -n "${OM_HARNESS_NODE:-}" && -x "$OM_HARNESS_NODE" ]]; then
    printf '%s\n' "$OM_HARNESS_NODE"
    return
  fi
  if candidate="$(command -v node 2>/dev/null)" && [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi
  # OM_HARNESS_NODE_DIRS replaces the usual install folders (the script tests use it to stay hermetic).
  for directory in ${OM_HARNESS_NODE_DIRS-"$HOME/.volta/bin" /opt/homebrew/bin /usr/local/bin}; do
    if [[ -x "$directory/node" ]]; then
      printf '%s\n' "$directory/node"
      return
    fi
  done
  nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  [[ -d "$nvm_dir/versions/node" ]] || return 0
  if [[ -r "$nvm_dir/alias/default" ]]; then
    default_version="$(tr -d '[:space:]' < "$nvm_dir/alias/default")"
    default_version="${default_version#v}"
    # The default alias may name a full version (24.13.1) or a prefix (24); take the newest match.
    candidate="$(ls -d "$nvm_dir/versions/node/v$default_version"* 2>/dev/null | sort -V | tail -n 1)"
    if [[ -n "$candidate" && -x "$candidate/bin/node" ]]; then
      printf '%s\n' "$candidate/bin/node"
      return
    fi
  fi
  candidate="$(ls -d "$nvm_dir"/versions/node/v*/bin/node 2>/dev/null | sort -V | tail -n 1)"
  [[ -n "$candidate" && -x "$candidate" ]] && printf '%s\n' "$candidate"
  return 0
}

om_harness_deny() {
  printf '[om-harness] %s\n' "$1" >&2
  exit 2
}

# The values of one JSON string field ("cwd", "file_path", ...) in the hook input, one per line. Good enough
# for paths; a field this cannot read only means fewer folders are checked, and the checks below fail closed.
om_harness_field() {
  printf '%s' "$2" | tr '\n' ' ' | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*:[[:space:]]*"//; s/"$//'
}

# Without Node the guard cannot parse the tool input, so it denies whenever a marker it would act on exists for a
# folder the call may touch: the hook's working directory, the input's "cwd" and, for edits, the edited files'
# folders. A staged-only run (any worktree of that repository) denies "block"; a frozen-test manifest above
# that folder denies "freeze". A folder whose repository cannot be read denies too, as the guard does.
# Otherwise there is nothing the guard would refuse, and the call goes ahead.
om_harness_without_node() {
  local mode="$1" input="$2" common directory start output
  local -a starts=("$PWD")
  while IFS= read -r start; do [[ -n "$start" ]] && starts+=("$start"); done < <(om_harness_field cwd "$input")
  case "$mode" in
    block)
      for start in "${starts[@]}"; do
        [[ -d "$start" ]] || continue
        if ! output="$(git -C "$start" rev-parse --path-format=absolute --git-common-dir 2>&1)"; then
          [[ "$output" == *"not a git repository"* ]] && continue
          om_harness_deny "Node.js was not found, and the repository at $start cannot be read: install Node or set OM_HARNESS_NODE."
        fi
        common="$output"
        if [[ -e "$common/om-harness/stage-only.json" ]] \
          || compgen -G "$common/worktrees/*/om-harness/stage-only.json" >/dev/null; then
          om_harness_deny "Node.js was not found, and a staged-only run is active: install Node or set OM_HARNESS_NODE."
        fi
      done
      ;;
    freeze)
      while IFS= read -r start; do
        [[ -n "$start" ]] || continue
        [[ "$start" == /* ]] || start="${starts[${#starts[@]}-1]}/$start"
        starts+=("$(dirname "$start")")
      done < <(om_harness_field file_path "$input"; om_harness_field notebook_path "$input")
      for directory in "${starts[@]}"; do
        while :; do
          [[ -e "$directory/.om-freeze-tests" ]] \
            && om_harness_deny "Node.js was not found, and tests are frozen: install Node or set OM_HARNESS_NODE."
          [[ "$directory" == "/" || "$directory" == "." ]] && break
          directory="$(dirname "$directory")"
        done
      done
      ;;
  esac
  return 0
}

om_harness_run() {
  local mode="$1" node
  node="$(om_harness_node)"
  if [[ -n "$node" ]]; then
    exec "$node" "$(dirname "${BASH_SOURCE[0]}")/guard.mjs" "$mode"
  fi
  om_harness_without_node "$mode" "$(cat)"
  exit 0
}
