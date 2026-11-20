# scripts/make-appcast.sh, scripts/sparkle-sign.sh and scripts/fetch-sparkle-tools.sh. Offline except where noted.
# Signing uses a throw-away Ed25519 key in a temporary FILE-free setup: the key lives in a shell variable and a temp
# directory that is deleted on exit; it never touches a keychain and is never committed.
source "${0:A:h}/lib.zsh"
mk="$ROOT/scripts/make-appcast.sh"
sg="$ROOT/scripts/sparkle-sign.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

dmg="$tmp/Lintel.dmg"; print -rn -- "fixture dmg" > "$dmg"
sig="$(printf 'S%.0s' {1..86})=="
notes="$tmp/notes.md"; printf '### Added\n\n- Fish & chips <b>bold</b> "quoted" and ]]> text  \n' > "$notes"
plist="$FIXTURES/Info.fixture.plist"

build() { # build <version> <build> <output> [previous]
  local args=(--version "$1" --build "$2" --dmg "$dmg" --signature "$sig" --notes "$notes" --output "$3" --info-plist "$ROOT/Resources/Info.plist" --pub-date "Fri, 20 Nov 2026 10:00:00 +0000")
  [[ -z "${4:-}" ]] || args+=(--previous "$4")
  "$mk" $args
}
item_count() { xmllint --xpath 'count(//item)' "$1"; }
versions() { xmllint --xpath '//*[local-name()="shortVersionString"]/text()' "$1" 2>/dev/null | tr -d ' ' ; }
channels() { xmllint --xpath 'count(//*[local-name()="channel"][text()="beta"])' "$1"; }
# The verbatim lines of the item with this short version
item_block() { awk -v v="<sparkle:shortVersionString>$2</sparkle:shortVersionString>" '/^        <item>$/{buf=""; keep=0} {buf=buf $0 "\n"} index($0,v){keep=1} /^        <\/item>$/{ if(keep) printf "%s", buf }' "$1"; }

# --- first release ever: one item, no channel on a stable
assert_ok "first stable release builds" build 0.1.0 100 "$tmp/first.xml"
assert_ok "first feed is well-formed" xmllint --noout "$tmp/first.xml"
assert_eq 1 "$(item_count "$tmp/first.xml")" "first release has one item"
assert_eq 0 "$(channels "$tmp/first.xml")" "a stable item has no beta channel"
first="$(<"$tmp/first.xml")"
assert_contains "$first" '<sparkle:version>100</sparkle:version>' "build is sparkle:version"
assert_contains "$first" '<sparkle:shortVersionString>0.1.0</sparkle:shortVersionString>' "short version"
assert_contains "$first" '<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>' "minimum system version from Info.plist"
assert_contains "$first" 'url="https://github.com/mjozefiak/lintel/releases/download/v0.1.0/Lintel.dmg"' "enclosure url names the tag"
assert_contains "$first" "sparkle:edSignature=\"$sig\"" "enclosure signature"
assert_contains "$first" 'length="11"' "enclosure length is the DMG size"
assert_contains "$first" '<description sparkle:format="markdown">' "notes are Markdown"
assert_contains "$first" 'Fish &amp; chips &lt;b&gt;bold&lt;/b&gt; &quot;quoted&quot; and ]]&gt; text  ' "notes are XML-escaped"
assert_eq "- Fish & chips <b>bold</b> \"quoted\" and ]]> text  " "$(xmllint --xpath 'string(//item/description)' "$tmp/first.xml" | tail -1)" "escaped notes parse back to the original"

# --- beta after a stable: two items, the beta carries the channel, the stable is kept byte for byte
assert_ok "beta after stable builds" build 0.2.0-beta.1 200 "$tmp/beta1.xml" "$tmp/first.xml"
assert_eq 2 "$(item_count "$tmp/beta1.xml")" "stable plus newer beta"
assert_eq 1 "$(channels "$tmp/beta1.xml")" "only the beta has the channel"
assert_eq "$(item_block "$tmp/first.xml" 0.1.0)" "$(item_block "$tmp/beta1.xml" 0.1.0)" "carried stable item is byte for byte"
assert_ok "two-item feed is well-formed" xmllint --noout "$tmp/beta1.xml"

# --- a new beta replaces the old beta, the stable stays
assert_ok "second beta builds" build 0.2.0-beta.2 300 "$tmp/beta2.xml" "$tmp/beta1.xml"
assert_eq 2 "$(item_count "$tmp/beta2.xml")" "still two items"
assert_contains "$(<"$tmp/beta2.xml")" '0.2.0-beta.2' "new beta present"
[[ "$(<"$tmp/beta2.xml")" != *'0.2.0-beta.1'* ]] && _pass || _fail "old beta replaced"
assert_eq "$(item_block "$tmp/first.xml" 0.1.0)" "$(item_block "$tmp/beta2.xml" 0.1.0)" "stable still byte for byte"

# --- stable release newer than the beta: the beta is dropped
assert_ok "stable after beta builds" build 0.2.0 400 "$tmp/stable2.xml" "$tmp/beta2.xml"
assert_eq 1 "$(item_count "$tmp/stable2.xml")" "beta older than the new stable is dropped"
assert_eq 0 "$(channels "$tmp/stable2.xml")" "no beta left"
[[ "$(<"$tmp/stable2.xml")" != *'0.1.0'* ]] && _pass || _fail "previous stable is replaced"

# --- stable release while a NEWER beta exists (hotfix on the stable line): the beta is kept byte for byte
assert_ok "hotfix stable builds" build 0.1.1 250 "$tmp/hotfix.xml" "$tmp/beta2.xml"
assert_eq 2 "$(item_count "$tmp/hotfix.xml")" "newer beta kept beside the new stable"
assert_eq "$(item_block "$tmp/beta2.xml" 0.2.0-beta.2)" "$(item_block "$tmp/hotfix.xml" 0.2.0-beta.2)" "carried beta item is byte for byte"
assert_contains "$(<"$tmp/hotfix.xml")" '0.1.1' "new stable present"

# --- a beta that is not newer than the stable fails and writes nothing
rm -f "$tmp/bad.xml"
assert_fails "beta not newer than the stable fails" build 0.3.0-beta.1 50 "$tmp/bad.xml" "$tmp/first.xml"
[[ ! -e "$tmp/bad.xml" ]] && _pass || _fail "failed run wrote the output"

# --- previous feeds that must fail
print -r -- '<rss><channel><item>' > "$tmp/malformed.xml"
assert_fails "malformed previous feed fails" build 0.3.0 500 "$tmp/bad.xml" "$tmp/malformed.xml"
print -r -- 'not xml at all' > "$tmp/notxml.xml"
assert_fails "non-XML previous feed fails" build 0.3.0 500 "$tmp/bad.xml" "$tmp/notxml.xml"
sed 's/<channel>/<channel><item><sparkle:version>1<\/sparkle:version><\/item>/' "$tmp/first.xml" > "$tmp/oddlayout.xml"
assert_fails "an item in another layout fails" build 0.3.0 500 "$tmp/bad.xml" "$tmp/oddlayout.xml"
sed 's/<sparkle:version>100</<sparkle:version>x</' "$tmp/first.xml" > "$tmp/badbuild.xml"
assert_fails "an item without a numeric build fails" build 0.3.0 500 "$tmp/bad.xml" "$tmp/badbuild.xml"
assert_fails "a missing previous file fails" build 0.3.0 500 "$tmp/bad.xml" "$tmp/nope.xml"
[[ ! -e "$tmp/bad.xml" ]] && _pass || _fail "failed runs wrote the output"

# --- a signature comment at the end of the previous feed is ignored (the caller verified it)
{ cat "$tmp/first.xml"; printf '<!-- sparkle-signatures:\nedSignature: abc\nlength: 1\n-->\n'; } > "$tmp/signed-prev.xml"
assert_ok "signed previous feed is read" build 0.2.0-beta.1 200 "$tmp/fromsigned.xml" "$tmp/signed-prev.xml"
assert_eq "$(<"$tmp/beta1.xml")" "$(<"$tmp/fromsigned.xml")" "the signature comment does not change the result"

# --- bad input
assert_fails "bad version" "$mk" --version v1.0.0 --build 1 --dmg "$dmg" --signature "$sig" --notes "$notes" --output "$tmp/x.xml"
assert_fails "bad build" "$mk" --version 1.0.0 --build 0 --dmg "$dmg" --signature "$sig" --notes "$notes" --output "$tmp/x.xml"
assert_fails "bad signature" "$mk" --version 1.0.0 --build 1 --dmg "$dmg" --signature 'a"b' --notes "$notes" --output "$tmp/x.xml"
: > "$tmp/empty.md"
assert_fails "empty notes" "$mk" --version 1.0.0 --build 1 --dmg "$dmg" --signature "$sig" --notes "$tmp/empty.md" --output "$tmp/x.xml"
assert_fails "missing option" "$mk" --version 1.0.0
[[ ! -e "$tmp/x.xml" ]] && _pass || _fail "bad input wrote output"

# --- signing and the key-pair check, with a throw-away key (offline)
tools="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
if [[ -x "$tools" ]] && command -v swift >/dev/null; then
  export SPARKLE_SIGN_UPDATE="$tools"
  key="$(openssl rand -base64 32)"
  other="$(openssl rand -base64 32)"
  pub="$(print -rn -- "$key" | swift "$ROOT/scripts/ed25519.swift" public-key)"
  cp "$FIXTURES/Info.fixture.plist" "$tmp/Info.match.plist"; plutil -insert SUPublicEDKey -string "$pub" "$tmp/Info.match.plist"
  cp "$FIXTURES/Info.fixture.plist" "$tmp/Info.other.plist"
  plutil -insert SUPublicEDKey -string "$(print -rn -- "$other" | swift "$ROOT/scripts/ed25519.swift" public-key)" "$tmp/Info.other.plist"
  cp "$FIXTURES/Info.fixture.plist" "$tmp/Info.nokey.plist"

  out="$(SPARKLE_ED_PRIVATE_KEY="$key" "$sg" check-key "$tmp/Info.match.plist" 2>&1)"; rc=$?
  assert_eq 0 "$rc" "matching key pair passes"
  assert_contains "$out" "matches SUPublicEDKey" "success message"
  out="$(SPARKLE_ED_PRIVATE_KEY="$other" "$sg" check-key "$tmp/Info.match.plist" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "a mismatched key pair fails"
  assert_contains "$out" "does not belong to SUPublicEDKey" "mismatch message"
  out2="$(SPARKLE_ED_PRIVATE_KEY="$key" "$sg" check-key "$tmp/Info.nokey.plist" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "a plist without a public key fails"
  out3="$(SPARKLE_ED_PRIVATE_KEY="not a key" "$sg" check-key "$tmp/Info.match.plist" 2>&1)"; rc=$?
  assert_eq 1 "$rc" "a malformed key fails"
  assert_fails "unset key fails" env -u SPARKLE_ED_PRIVATE_KEY "$sg" check-key "$tmp/Info.match.plist"
  for o in "$out" "$out2" "$out3"; do
    [[ "$o" != *"$key"* && "$o" != *"$other"* && "$o" != *"not a key"* ]] && _pass || _fail "output shows a private key"
  done
  # the DMG signature is the one CryptoKit accepts for the plist's public key
  s="$(SPARKLE_ED_PRIVATE_KEY="$key" "$sg" sign-file "$dmg")"
  assert_ok "file signature verifies against the public key" swift "$ROOT/scripts/ed25519.swift" verify "$pub" "$dmg" "$s"

  # a signed feed: verifies, keeps its bytes, fails on tampering, fails for another key, and re-signing is stable
  cp "$tmp/beta1.xml" "$tmp/signed.xml"
  assert_ok "feed signs" env SPARKLE_ED_PRIVATE_KEY="$key" "$sg" sign-feed "$tmp/signed.xml"
  assert_ok "signed feed verifies" env SPARKLE_ED_PRIVATE_KEY="$key" "$sg" verify-feed "$tmp/signed.xml"
  assert_ok "signed feed is well-formed" xmllint --noout "$tmp/signed.xml"
  assert_eq "$(<"$tmp/beta1.xml")" "$(awk '/^<!-- sparkle-signatures:/{exit}{print}' "$tmp/signed.xml")" "the signature is appended, the feed is unchanged"
  assert_fails "feed does not verify for another key" env SPARKLE_ED_PRIVATE_KEY="$other" "$sg" verify-feed "$tmp/signed.xml"
  sed 's/0.1.0/9.9.9/' "$tmp/signed.xml" > "$tmp/tampered.xml"
  assert_fails "a tampered feed does not verify" env SPARKLE_ED_PRIVATE_KEY="$key" "$sg" verify-feed "$tmp/tampered.xml"
  assert_fails "an unsigned feed does not verify" env SPARKLE_ED_PRIVATE_KEY="$key" "$sg" verify-feed "$tmp/beta1.xml"
  # the signed feed is a valid --previous: items come through unchanged
  assert_ok "signed feed is accepted as previous" build 0.2.0-beta.2 300 "$tmp/again.xml" "$tmp/signed.xml"
  assert_eq "$(item_block "$tmp/beta1.xml" 0.1.0)" "$(item_block "$tmp/again.xml" 0.1.0)" "stable byte for byte after the signed round trip"
else
  print "note: sign_update (.build artifact) or swift not available, signing tests skipped"
fi

# --- previous-release.sh: a stub `gh` (as in test_release_order.zsh) serves release pages
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/bin/zsh
filter=""; paged=0
while (( $# )); do case "$1" in --jq) filter="$2"; shift 2 ;; --paginate) paged=1; shift ;; *) shift ;; esac; done
for page in ${(s: :)STUB_PAGES}; do jq -r "$filter" "$page" || exit 1; done
STUB
chmod +x "$tmp/bin/gh"
print -r -- '[{"tag_name":"v0.9.0","draft":true,"published_at":null},{"tag_name":"v0.2.0-beta.1","draft":false,"published_at":"2026-11-20T10:00:00Z"}]' > "$tmp/pg1.json"
print -r -- '[{"tag_name":"v0.1.0","draft":false,"published_at":"2026-11-19T10:00:00Z"}]' > "$tmp/pg2.json"
prev() { PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r STUB_PAGES="$1" bash "$ROOT/scripts/previous-release.sh" "$2"; }
assert_eq "v0.2.0-beta.1" "$(prev "$tmp/pg2.json $tmp/pg1.json" v0.3.0)" "newest published release, drafts ignored, any page"
assert_eq "v0.1.0" "$(prev "$tmp/pg1.json $tmp/pg2.json" v0.2.0-beta.1)" "the run's own tag is not its predecessor"
assert_eq "" "$(prev "$tmp/pg2.json" v0.1.0)" "no previous release prints nothing"
assert_fails "no tag is refused" env PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r bash "$ROOT/scripts/previous-release.sh"

# --- the pinned Sparkle tools match the package pin; the download check refuses a wrong checksum (offline)
want="$(sed -n 's/^VERSION=//p' "$ROOT/scripts/sparkle-tools.txt")"
assert_contains "$(<"$ROOT/Package.swift")" "Sparkle.git\", exact: \"$want\"" "sparkle-tools.txt names the version Package.swift pins"
chk="$ROOT/.build/checkouts/Sparkle/Package.swift"
if [[ -f "$chk" ]]; then
  assert_contains "$(<"$chk")" "checksum = \"$(sed -n 's/^SHA256=//p' "$ROOT/scripts/sparkle-tools.txt")\"" "SHA256 equals SwiftPM's pinned checksum"
fi
print -r -- junk > "$tmp/wrong.zip"
assert_fails "a download with the wrong checksum is refused" "$ROOT/scripts/fetch-sparkle-tools.sh" "$tmp/tools" "$tmp/wrong.zip"
[[ ! -e "$tmp/tools/bin/sign_update" ]] && _pass || _fail "nothing is extracted before the check"

finish
