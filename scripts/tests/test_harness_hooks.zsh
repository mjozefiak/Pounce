source "${0:A:h}/lib.zsh"
hooks="$ROOT/.claude/hooks/om-harness"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A hermetic environment: no node on the PATH, no usual install folders, an empty nvm folder.
base_path="/usr/bin:/bin:/usr/sbin:/sbin"
run_hook() { # <hook> <cwd> [VAR=value...]; the hook input is $INPUT (a harmless command by default)
  local hook="$1" cwd="$2"; shift 2
  (cd "$cwd" && print -r -- "${INPUT:-{\"tool_input\":{\"command\":\"true\"}}}" \
    | env -i HOME="$tmp/home" PATH="$base_path" NVM_DIR="$tmp/nvm" OM_HARNESS_NODE_DIRS="" "$@" "$hooks/$hook")
}
mkdir -p "$tmp/home" "$tmp/nvm"

# A stub node that records how it was called.
stub_node() { # <path>
  mkdir -p "${1:h}"
  print -r -- "#!/bin/sh
echo \"\$0 \$*\" > \"$tmp/called\"
exit 0" > "$1"
  chmod +x "$1"
}

# A plain repository and a working directory outside it.
repo="$tmp/repo"
git init -q "$repo"

# nvm's default alias (a prefix) picks the newest matching version, not a newer major
stub_node "$tmp/nvm/versions/node/v20.1.0/bin/node"
stub_node "$tmp/nvm/versions/node/v20.9.0/bin/node"
stub_node "$tmp/nvm/versions/node/v24.1.0/bin/node"
mkdir -p "$tmp/nvm/alias"; print 20 > "$tmp/nvm/alias/default"
rm -f "$tmp/called"
run_hook block-push-and-pr.sh "$repo"; assert_eq 0 $? "block runs through the nvm default"
assert_contains "$(cat "$tmp/called" 2>/dev/null)" "v20.9.0/bin/node" "the newest version of the default alias is used"
assert_contains "$(cat "$tmp/called" 2>/dev/null)" "guard.mjs block" "the guard gets the block mode"

# without an alias, the newest installed version is used
rm -f "$tmp/nvm/alias/default" "$tmp/called"
run_hook freeze-tests.sh "$repo"; assert_eq 0 $? "freeze runs through nvm without an alias"
assert_contains "$(cat "$tmp/called" 2>/dev/null)" "v24.1.0/bin/node" "the newest installed version is used"
assert_contains "$(cat "$tmp/called" 2>/dev/null)" "guard.mjs freeze" "the guard gets the freeze mode"

# OM_HARNESS_NODE wins over everything else
stub_node "$tmp/custom/node"
rm -f "$tmp/called"
run_hook block-push-and-pr.sh "$repo" OM_HARNESS_NODE="$tmp/custom/node"
assert_contains "$(cat "$tmp/called" 2>/dev/null)" "$tmp/custom/node" "OM_HARNESS_NODE is used first"

# no node anywhere: nothing to refuse means the call goes ahead
rm -rf "$tmp/nvm/versions" "$tmp/called"
run_hook block-push-and-pr.sh "$repo"; assert_eq 0 $? "block without node and without a staged run allows"
run_hook freeze-tests.sh "$repo"; assert_eq 0 $? "freeze without node and without frozen tests allows"
assert_eq "" "$(cat "$tmp/called" 2>/dev/null)" "no node was run"

# no node and a staged-only run: refused (in the main worktree and in a linked one)
mkdir -p "$repo/.git/om-harness"
print -r -- '{}' > "$repo/.git/om-harness/stage-only.json"
out="$(run_hook block-push-and-pr.sh "$repo" 2>&1)"; rc=$?
assert_eq 2 $rc "block without node during a staged run denies"
assert_contains "$out" "staged-only run is active" "the denial says why"
rm -rf "$repo/.git/om-harness"
git -C "$repo" commit -q --allow-empty -m init
git -C "$repo" worktree add -q "$tmp/linked" 2>/dev/null
mkdir -p "$repo/.git/worktrees/linked/om-harness"
print -r -- '{}' > "$repo/.git/worktrees/linked/om-harness/stage-only.json"
run_hook block-push-and-pr.sh "$repo" >/dev/null 2>&1; assert_eq 2 $? "a staged run in a linked worktree is seen from the main one"

# the input's cwd counts, not only the hook's working directory
INPUT="{\"tool_input\":{\"command\":\"git push\"},\"cwd\":\"$repo\"}" run_hook block-push-and-pr.sh "$tmp/home" >/dev/null 2>&1
assert_eq 2 $? "a staged run in the input's cwd denies from another working directory"


# no node and frozen tests above the working directory: refused
mkdir -p "$tmp/frozen/a/b"
print -r -- '[]' > "$tmp/frozen/.om-freeze-tests"
run_hook freeze-tests.sh "$tmp/frozen/a/b" >/dev/null 2>&1; assert_eq 2 $? "freeze without node under a frozen-test manifest denies"
INPUT="{\"tool_input\":{\"file_path\":\"$tmp/frozen/a/b/Tests/x.swift\"},\"cwd\":\"$tmp/home\"}" run_hook freeze-tests.sh "$tmp/home" >/dev/null 2>&1
assert_eq 2 $? "the edited file's folder counts, not only the working directory"
INPUT="{\"tool_input\":{\"file_path\":\"$tmp/home/Tests/x.swift\"},\"cwd\":\"$tmp/home\"}" run_hook freeze-tests.sh "$tmp/home" >/dev/null 2>&1
assert_eq 0 $? "an edit outside any manifest is allowed"

# with a real node (when one exists here), a harmless command passes the real guard
real_node="$(OM_HARNESS_NODE_DIRS= bash -c "source '$hooks/node.sh'; om_harness_node")"
if [[ -n "$real_node" ]]; then
  rm -rf "$repo/.git/worktrees/linked/om-harness"
  run_hook block-push-and-pr.sh "$repo" OM_HARNESS_NODE="$real_node"; assert_eq 0 $? "the real guard allows a harmless command"
  mkdir -p "$repo/.git/worktrees/linked/om-harness"
  print -r -- '{"version":1,"runId":"t","startState":"/tmp"}' > "$repo/.git/worktrees/linked/om-harness/stage-only.json"
  INPUT="{\"tool_input\":{\"command\":\"git push origin main\"},\"cwd\":\"$tmp/linked\"}" run_hook block-push-and-pr.sh "$tmp/linked" OM_HARNESS_NODE="$real_node" >/dev/null 2>&1
  assert_eq 2 $? "the real guard denies a push during a staged run"
fi

finish
