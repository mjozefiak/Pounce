source "${0:A:h}/lib.zsh"
upd="$ROOT/scripts/update-cask.sh"
cf="$FIXTURES/cask"
sha="$(printf 'a%.0s' {1..64})"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

tree() { (cd "$1" && print -l -- *(.N) | sort | tr '\n' ' '); }

# stable: both casks, identical to the expected files
assert_ok "renders a stable release" "$upd" 0.1.0 "$sha" "$tmp/stable"
assert_eq "lintel.rb lintel@beta.rb " "$(tree "$tmp/stable")" "stable writes both casks"
for f in lintel.rb lintel@beta.rb; do
  assert_ok "stable $f matches the expected file" diff "$cf/stable/$f" "$tmp/stable/$f"
done
assert_contains "$(<"$tmp/stable/lintel.rb")" 'version "0.1.0"' "stable version"
assert_contains "$(<"$tmp/stable/lintel.rb")" "sha256 \"$sha\"" "stable checksum"
assert_contains "$(<"$tmp/stable/lintel.rb")" 'conflicts_with cask: "lintel@beta"' "stable conflicts with beta"
assert_contains "$(<"$tmp/stable/lintel@beta.rb")" 'conflicts_with cask: "lintel"' "beta conflicts with stable"

# beta: only the beta cask
assert_ok "renders a beta release" "$upd" 0.2.0-beta.3 "$sha" "$tmp/beta"
assert_eq "lintel@beta.rb " "$(tree "$tmp/beta")" "beta writes only lintel@beta"
assert_ok "beta cask matches the expected file" diff "$cf/beta/lintel@beta.rb" "$tmp/beta/lintel@beta.rb"
assert_contains "$(<"$tmp/beta/lintel@beta.rb")" 'version "0.2.0-beta.3"' "beta version"

# a repeat run changes nothing
before="$(shasum "$tmp/stable"/*.rb)"
assert_contains "$("$upd" 0.1.0 "$sha" "$tmp/stable")" "unchanged" "repeat run reports unchanged"
assert_eq "$before" "$(shasum "$tmp/stable"/*.rb)" "repeat run leaves the files alone"

# bad input: exit non-zero, nothing written
for v in v0.1.0 0.1 0.1.0-rc.1 01.0.0 0.1.0-beta.0 0.1.0-beta "" "0.1.0 " $'0.1.0\n' 0.1.0/x '0.1.0&'; do
  assert_fails "version '$v' is rejected" "$upd" "$v" "$sha" "$tmp/bad"
done
for s in "" abc "${sha:0:63}" "${sha}a" "${(U)sha}" "${sha:0:63}g" "${sha:0:63}/"; do
  assert_fails "checksum '$s' is rejected" "$upd" 0.1.0 "$s" "$tmp/bad"
done
assert_fails "no argument is rejected" "$upd"
assert_fails "one argument is rejected" "$upd" 0.1.0
assert_fails "four arguments are rejected" "$upd" 0.1.0 "$sha" "$tmp/bad" extra
assert_contains "$("$upd" 0.1 "$sha" "$tmp/bad" 2>&1)" "Not a version" "bad version explains itself"
assert_contains "$("$upd" 0.1.0 zz "$tmp/bad" 2>&1)" "Not a SHA-256" "bad checksum explains itself"
[[ ! -e "$tmp/bad" ]] && _pass || _fail "bad input wrote something"

# Ruby syntax of every rendered cask
if command -v ruby >/dev/null; then
  for f in "$tmp"/stable/*.rb "$tmp"/beta/*.rb; do assert_ok "ruby -c ${f:t}" ruby -c "$f"; done
else
  print "note: ruby not installed, syntax check skipped"
fi

# brew style on the rendered casks (copied into a tap-like path, because brew only treats those as casks)
if command -v brew >/dev/null; then
  mkdir -p "$tmp/tap/homebrew-lintel/Casks"
  cp "$tmp"/stable/*.rb "$tmp/tap/homebrew-lintel/Casks/"
  assert_ok "brew style passes" brew style "$tmp"/tap/homebrew-lintel/Casks/*.rb
else
  print "note: brew not installed, brew style skipped (brew audit --cask needs a real tap and is not run here)"
fi
finish
