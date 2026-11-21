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

# --- previous feeds this script would not have written fail closed, with a reason
fail_reason() { local m; m="$("$@" 2>&1)" && { _fail "expected a failure: $*"; return }; print -r -- "$m" }
two="$(item_block "$tmp/first.xml" 0.1.0)"; print -r -- "$two" | sed 's/0\.1\.0/0.0.9/' > "$tmp/extra.item"
insert_extra() { awk -v f="$tmp/extra.item" 'index($0,"    </channel>"){while((getline l < f)>0) print l} {print}' "$1" > "$2"; }
insert_extra "$tmp/first.xml" "$tmp/twostable.xml"
assert_contains "$(fail_reason build 0.3.0 500 "$tmp/bad.xml" "$tmp/twostable.xml")" "two stable items" "two stable items in the previous feed fail"
insert_extra "$tmp/beta1.xml" "$tmp/threeitems.xml"
assert_contains "$(fail_reason build 0.3.0 500 "$tmp/bad.xml" "$tmp/threeitems.xml")" "more than two items" "a previous feed with three items fails"
sed 's#<sparkle:channel>beta</sparkle:channel>#<sparkle:channel>nightly</sparkle:channel>#' "$tmp/beta1.xml" > "$tmp/unknownchannel.xml"
assert_contains "$(fail_reason build 0.3.0 500 "$tmp/bad.xml" "$tmp/unknownchannel.xml")" "unknown channel 'nightly'" "an unknown channel fails closed"
# --- a build number never goes down or stays: not higher than the item of its own channel that it replaces
assert_contains "$(fail_reason build 0.1.1 100 "$tmp/bad.xml" "$tmp/first.xml")" "not newer than the stable it replaces" "a stable with the same build as the stable it replaces fails"
assert_contains "$(fail_reason build 0.1.1 99 "$tmp/bad.xml" "$tmp/first.xml")" "not newer than the stable it replaces" "a stable with a lower build fails"
assert_contains "$(fail_reason build 0.2.0-beta.2 200 "$tmp/bad.xml" "$tmp/beta1.xml")" "not newer than the beta it replaces" "a beta with the same build as the beta it replaces fails"
assert_contains "$(fail_reason build 0.2.0-beta.2 150 "$tmp/bad.xml" "$tmp/beta1.xml")" "not newer than" "a beta with a lower build fails"
[[ ! -e "$tmp/bad.xml" ]] && _pass || _fail "failed runs wrote the output"
# --- pubDate is English whatever the locale
LC_ALL=pl_PL.UTF-8 build 0.1.0 100 "$tmp/loc.xml" >/dev/null 2>&1
assert_contains "$(<"$tmp/loc.xml")" '<pubDate>Fri, 20 Nov 2026 10:00:00 +0000</pubDate>' "pubDate is as given"

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

  # --- sign_update's own error quotes a malformed key; nothing of it may reach the output (fixed messages only)
  bad="MALFORMEDSECRETKEYTEXT0123456789abcdef"
  for cmd in "check-key $tmp/Info.match.plist" "sign-file $dmg" "sign-feed $tmp/signed.xml" "verify-feed $tmp/signed.xml"; do
    cp "$tmp/beta1.xml" "$tmp/signed.xml"
    o="$(SPARKLE_ED_PRIVATE_KEY="$bad" "$sg" ${=cmd} 2>&1)"; rc=$?
    assert_eq 1 "$rc" "a malformed key fails: ${cmd%% *}"
    [[ "$o" != *MALFORMEDSECRET* && "$o" != *"decode"* ]] && _pass || _fail "output of ${cmd%% *} shows sign_update's text or the key: $o"
    [[ -n "$o" ]] && _pass || _fail "a failure says something (${cmd%% *})"
  done
  # --- only sign_update gets the key: swift (and every other child) runs without it
  mkdir -p "$tmp/swiftbin"
  printf '#!/bin/sh\nprintf "%%s" "${SPARKLE_ED_PRIVATE_KEY+leaked}" > "%s/swift-env"\nexit 0\n' "$tmp" > "$tmp/swiftbin/swift"
  chmod +x "$tmp/swiftbin/swift"
  out="$(PATH="$tmp/swiftbin:$PATH" SPARKLE_ED_PRIVATE_KEY="$key" "$sg" check-key "$tmp/Info.match.plist" 2>&1)"
  assert_contains "$out" "matches SUPublicEDKey" "check-key ran with the stub swift"
  assert_eq "" "$(<"$tmp/swift-env")" "swift does not see SPARKLE_ED_PRIVATE_KEY"

  # --- scripts/release-appcast.sh with real signing: the body of the workflow step
  ra="$ROOT/scripts/release-appcast.sh"
  cp "$FIXTURES/Info.fixture.plist" "$tmp/Info.app.plist"
  plutil -replace CFBundleShortVersionString -string 0.2.0-beta.1 "$tmp/Info.app.plist"
  plutil -replace CFBundleVersion -string 200 "$tmp/Info.app.plist"
  plutil -insert LSMinimumSystemVersion -string 26.0 "$tmp/Info.app.plist"
  printf '## [0.2.0-beta.1] - 2026-11-20\n\n### Added\n\n- A thing\n' > "$tmp/CHANGELOG.md"
  run_ra() { # run_ra <work> <tag-run> <ref> [key]
    env IS_TAG_RUN="$2" GITHUB_REF_NAME="$3" SPARKLE_SIGN_UPDATE="$tools" SPARKLE_ED_PRIVATE_KEY="${4:-$key}" CHANGELOG="$tmp/CHANGELOG.md" \
      "$ra" "$tmp/Info.app.plist" "$dmg" "$1" 2>&1
  }
  mkwork() { rm -rf "$tmp/work"; mkdir -p "$tmp/work/previous"; print -r -- "$tmp/work" }
  sign_with() { cp "$1" "$2"; env SPARKLE_ED_PRIVATE_KEY="$3" "$sg" sign-feed "$2" >/dev/null 2>&1 }

  w="$(mkwork)"; sign_with "$tmp/first.xml" "$w/previous/appcast.xml" "$key"
  out="$(run_ra "$w" true v0.2.0-beta.1)"; rc=$?
  assert_eq 0 "$rc" "a tag run with a verifying previous feed succeeds"
  assert_ok "the feed is written and verifies" env SPARKLE_ED_PRIVATE_KEY="$key" "$sg" verify-feed "$w/appcast.xml"
  assert_eq 2 "$(item_count "$w/appcast.xml")" "stable plus beta"
  assert_contains "$out" "2 item(s)" "item count is printed"
  [[ "$out" != *"$key"* ]] && _pass || _fail "the key is in the output"
  assert_eq "" "$(find "$w" -name '.stage.*' -o -name notes.md)" "no temporary files are left"

  w="$(mkwork)"; sign_with "$tmp/first.xml" "$w/previous/appcast.xml" "$other"
  run_ra "$w" true v0.2.0-beta.1 >/dev/null; rc=$?
  assert_eq 1 "$rc" "a previous feed signed with another key fails the run"
  [[ ! -e "$w/appcast.xml" ]] && _pass || _fail "a failed run left a feed"
  w="$(mkwork)"; cp "$tmp/first.xml" "$w/previous/appcast.xml"
  run_ra "$w" true v0.2.0-beta.1 >/dev/null; rc=$?
  assert_eq 1 "$rc" "an unsigned previous feed fails the run"
  [[ ! -e "$w/appcast.xml" ]] && _pass || _fail "a failed run left a feed (unsigned previous)"
  w="$(mkwork)"; rmdir "$w/previous"
  run_ra "$w" true v0.2.0-beta.1 >/dev/null; rc=$?
  assert_eq 0 "$rc" "no previous feed: the feed starts here"
  assert_eq 1 "$(item_count "$w/appcast.xml")" "a first feed has one item"
  w="$(mkwork)"
  run_ra "$w" true v0.3.0 >/dev/null; rc=$?
  assert_eq 1 "$rc" "a tag that differs from the app's version fails"
  run_ra "$w" true v0.2.0-beta.1 "$bad" >/dev/null; rc=$?
  assert_eq 1 "$rc" "a malformed key fails the run"
  [[ ! -e "$w/appcast.xml" ]] && _pass || _fail "a failed run left a feed (key)"
  CHANGELOG="$tmp/nochangelog" env IS_TAG_RUN=true GITHUB_REF_NAME=v0.2.0-beta.1 SPARKLE_SIGN_UPDATE="$tools" SPARKLE_ED_PRIVATE_KEY="$key" "$ra" "$tmp/Info.app.plist" "$dmg" "$w" >/dev/null 2>&1
  assert_eq 1 "$?" "a missing changelog section fails the run"
  env -u IS_TAG_RUN SPARKLE_SIGN_UPDATE="$tools" SPARKLE_ED_PRIVATE_KEY="$key" "$ra" "$tmp/Info.app.plist" "$dmg" "$w" >/dev/null 2>&1
  assert_eq 64 "$?" "IS_TAG_RUN must be set"

  # a manual (non-tag) run exercises everything and keeps nothing: the feed would be 0.0.0 signed with the production key
  w="$(mkwork)"; sign_with "$tmp/first.xml" "$w/previous/appcast.xml" "$key"
  out="$(run_ra "$w" false "")"; rc=$?
  assert_eq 0 "$rc" "a manual run succeeds"
  assert_contains "$out" "signature verified" "a manual run says that verification passed"
  assert_contains "$out" "item(s)" "a manual run prints the item count"
  assert_eq "" "$(find "$w" -name 'appcast.xml' -not -path '*/previous/*')" "a manual run keeps no feed"
  w="$(mkwork)"; sign_with "$tmp/first.xml" "$w/previous/appcast.xml" "$other"
  run_ra "$w" false "" >/dev/null; rc=$?
  assert_eq 1 "$rc" "a manual run still fails when the previous feed does not verify"
else
  if [[ "${CI:-}" == true ]]; then
    _fail "sign_update ($tools) or swift is missing on CI: run these tests after swift build, never skip the signing tests"
  else
    print "note: sign_update (.build artifact) or swift not available, signing tests skipped (they are a failure when CI=true)"
  fi
fi

# --- previous-release.sh, fetch-previous-appcast.sh, check-appcast-base.sh: a stub `gh` serves release pages
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/bin/zsh
# gh api --paginate <path> --jq <filter>   : prints the filter over every page in STUB_PAGES (fails with STUB_API_FAIL)
# gh release download <tag> --repo R --pattern P --dir D : copies STUB_APPCAST (fails with STUB_DOWNLOAD_FAIL)
if [[ "$1" == api ]]; then
  [[ -z "${STUB_API_FAIL:-}" ]] || { print -u2 "gh: HTTP 502"; exit 1; }
  filter=""; shift
  while (( $# )); do case "$1" in --jq) filter="$2"; shift 2 ;; *) shift ;; esac; done
  for page in ${(s: :)STUB_PAGES}; do jq -r "$filter" "$page" || exit 1; done
elif [[ "$1 $2" == "release download" ]]; then
  [[ -z "${STUB_DOWNLOAD_FAIL:-}" ]] || { print -u2 "gh: download failed"; exit 1; }
  tag="$3"; dir=""; shift 3
  while (( $# )); do case "$1" in --dir) dir="$2"; shift 2 ;; *) shift ;; esac; done
  print -r -- "$tag" >> "$STUB_LOG"
  cp "$STUB_APPCAST" "$dir/appcast.xml"
else
  exit 2
fi
STUB
chmod +x "$tmp/bin/gh"
print -r -- '[{"tag_name":"v0.9.0","draft":true,"published_at":null,"assets":[{"name":"appcast.xml"}]},{"tag_name":"v0.2.0-beta.1","draft":false,"published_at":"2026-11-20T10:00:00Z","assets":[{"name":"Lintel.dmg"},{"name":"appcast.xml"}]}]' > "$tmp/pg1.json"
print -r -- '[{"tag_name":"v0.1.0","draft":false,"published_at":"2026-11-19T10:00:00Z","assets":[{"name":"appcast.xml"}]}]' > "$tmp/pg2.json"
print -r -- '[{"tag_name":"v0.3.0-beta.1","draft":false,"published_at":"2026-11-21T10:00:00Z","assets":[{"name":"Lintel.dmg"}]}]' > "$tmp/pg3.json"
print -r -- '[{"tag_name":"v0.0.1","draft":false,"published_at":"2026-11-18T10:00:00Z"}]' > "$tmp/pg4.json"
prev() { PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r STUB_PAGES="$1" bash "$ROOT/scripts/previous-release.sh" "$2"; }
assert_eq "v0.2.0-beta.1" "$(prev "$tmp/pg2.json $tmp/pg1.json" v0.3.0)" "newest published release with a feed, drafts ignored, any page"
assert_eq "v0.1.0" "$(prev "$tmp/pg1.json $tmp/pg2.json" v0.2.0-beta.1)" "the run's own tag is not its predecessor"
assert_eq "" "$(prev "$tmp/pg2.json" v0.1.0)" "no previous release prints nothing"
assert_eq "v0.2.0-beta.1" "$(prev "$tmp/pg3.json $tmp/pg1.json" v0.4.0)" "a newer release without appcast.xml is skipped (spec D17)"
assert_eq "" "$(prev "$tmp/pg3.json $tmp/pg4.json" v0.4.0)" "releases without appcast.xml (or without an assets list) are no previous feed"
assert_fails "no tag is refused" env PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r bash "$ROOT/scripts/previous-release.sh"
assert_fails "a failing gh fails previous-release.sh" env STUB_API_FAIL=1 PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r STUB_PAGES="$tmp/pg1.json" bash "$ROOT/scripts/previous-release.sh" v0.3.0
out="$(STUB_API_FAIL=1 PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r STUB_PAGES="$tmp/pg1.json" bash "$ROOT/scripts/previous-release.sh" v0.3.0 2>/dev/null)"
assert_eq "" "$out" "a failing gh prints no tag"

fp="$ROOT/scripts/fetch-previous-appcast.sh"
fetch() { # fetch <pages> <tag> <outdir>; env: STUB_*
  PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r STUB_PAGES="$1" STUB_LOG="$tmp/gh.log" STUB_APPCAST="${STUB_APPCAST:-$tmp/first.xml}" bash "$fp" "$3" "$2"
}
: > "$tmp/gh.log"
out="$(fetch "$tmp/pg2.json $tmp/pg1.json" v0.3.0 "$tmp/f1" 2>&1)"; rc=$?
assert_eq 0 "$rc" "a previous release with a feed: success"
assert_eq "v0.2.0-beta.1" "$(<"$tmp/f1/previous-tag.txt")" "the tag the feed is built on is recorded"
assert_eq "$(<"$tmp/first.xml")" "$(<"$tmp/f1/previous/appcast.xml")" "the previous feed is downloaded"
assert_eq "v0.2.0-beta.1" "$(<"$tmp/gh.log")" "the download names that release"
out="$(fetch "$tmp/pg3.json" v0.4.0 "$tmp/f2" 2>&1)"; rc=$?
assert_eq 0 "$rc" "no release with a feed: success, the feed starts here"
assert_eq "" "$(<"$tmp/f2/previous-tag.txt")" "no previous tag is recorded"
[[ ! -e "$tmp/f2/previous/appcast.xml" ]] && _pass || _fail "a feed appeared from nowhere"
fetch "$tmp/pg1.json" v0.4.0 "$tmp/f3" >/dev/null 2>&1
STUB_API_FAIL=1 fetch "$tmp/pg1.json" v0.4.0 "$tmp/f3" >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" "a failing gh (5xx, rate limit) fails, it is not 'no previous release'"
rm -rf "$tmp/f4"; STUB_API_FAIL=1 fetch "$tmp/pg1.json" v0.4.0 "$tmp/f4" >/dev/null 2>&1
assert_eq 1 "$?" "a failing gh on a clean directory fails"
[[ "$(<"$tmp/f4/previous-tag.txt")" == "" && ! -e "$tmp/f4/previous/appcast.xml" ]] && _pass || _fail "a failed fetch left a previous feed or tag"
STUB_DOWNLOAD_FAIL=1 fetch "$tmp/pg1.json" v0.4.0 "$tmp/f5" >/dev/null 2>&1
assert_eq 1 "$?" "a failing download fails"
[[ "$(<"$tmp/f5/previous-tag.txt")" == "" ]] && _pass || _fail "a failed download recorded a previous tag"
: > "$tmp/empty.xml"; STUB_APPCAST="$tmp/empty.xml" fetch "$tmp/pg1.json" v0.4.0 "$tmp/f6" >/dev/null 2>&1
assert_eq 1 "$?" "an empty download fails"
out="$(STUB_API_FAIL=1 fetch "$tmp/pg1.json" "" "$tmp/f7" 2>&1)"; rc=$?
assert_eq 0 "$rc" "a run that is not a tag run fetches nothing (and does not call gh)"
assert_eq "" "$(<"$tmp/f7/previous-tag.txt")" "a non-tag run has no previous tag"
assert_fails "missing arguments are refused" bash "$fp" "$tmp/f8"

cb="$ROOT/scripts/check-appcast-base.sh"
guard() { PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r STUB_PAGES="$1" bash "$cb" "$2" "$3"; }
print -r -- "v0.2.0-beta.1" > "$tmp/built-on.txt"; : > "$tmp/built-on-none.txt"; print -r -- "v0.1.0" > "$tmp/built-on-old.txt"
assert_ok "the guard passes when the feed was built on the newest release with a feed" guard "$tmp/pg2.json $tmp/pg1.json" "$tmp/built-on.txt" v0.3.0
assert_fails "the guard fails when a newer release with a feed appeared" guard "$tmp/pg2.json $tmp/pg1.json" "$tmp/built-on-old.txt" v0.3.0
assert_fails "the guard fails when the feed was built on nothing but a release exists" guard "$tmp/pg1.json" "$tmp/built-on-none.txt" v0.3.0
assert_ok "the guard passes when there was and is none" guard "$tmp/pg3.json" "$tmp/built-on-none.txt" v0.4.0
assert_fails "the guard fails when gh fails" env STUB_API_FAIL=1 PATH="$tmp/bin:$PATH" GITHUB_REPOSITORY=o/r STUB_PAGES="$tmp/pg1.json" bash "$cb" "$tmp/built-on.txt" v0.3.0
assert_fails "the guard needs its arguments" bash "$cb" "$tmp/nope.txt" v0.3.0

# --- wait-for-site-feed.sh: a deadline, warnings only, never a failure
wf="$ROOT/scripts/wait-for-site-feed.sh"
cp "$tmp/first.xml" "$tmp/feed.xml"; cp "$tmp/first.xml" "$tmp/live.xml"
out="$(SITE_REBUILD_REQUESTED=true bash "$wf" "$tmp/feed.xml" --url "file://$tmp/live.xml" --deadline 5 --interval 1 2>&1)"; rc=$?
assert_eq 0 "$rc" "the site already serves the feed"
assert_contains "$out" "serves the new feed" "success message"
[[ "$out" != *"::warning::"* ]] && _pass || _fail "no warning when the dispatch was sent and the feed is live"
print -r -- "different" > "$tmp/live.xml"
SECONDS=0
out="$(SITE_REBUILD_REQUESTED=true bash "$wf" "$tmp/feed.xml" --url "file://$tmp/live.xml" --deadline 3 --interval 1 2>&1)"; rc=$?
assert_eq 0 "$rc" "a feed that never arrives is a warning, not a failure"
assert_contains "$out" "::warning::file://$tmp/live.xml still differs" "the warning names the live feed"
(( SECONDS <= 8 )) && _pass || _fail "the wait is bounded by the deadline (took ${SECONDS}s for 3)"
out="$(bash "$wf" "$tmp/feed.xml" --url "file://$tmp/live.xml" --deadline 1 --interval 1 2>&1)"; rc=$?
assert_eq 0 "$rc" "without a dispatch the script still ends with success"
assert_contains "$out" "was not asked to rebuild" "a missing dispatch is warned about"
assert_contains "$out" "by hand" "the warning says what to do"
assert_contains "$out" "still differs" "the poll still runs without a dispatch"
(sleep 1; cp "$tmp/feed.xml" "$tmp/live.xml") &
out="$(SITE_REBUILD_REQUESTED=true bash "$wf" "$tmp/feed.xml" --url "file://$tmp/live.xml" --deadline 8 --interval 1 2>&1)"; rc=$?
wait
assert_contains "$out" "serves the new feed" "a feed that arrives later is noticed"
assert_fails "an unknown option is refused" bash "$wf" "$tmp/feed.xml" --nope 1
assert_fails "a missing feed file is refused" bash "$wf" "$tmp/none.xml"

# --- the pinned Sparkle tools match the package pin; the download check refuses a wrong checksum (offline)
want="$(sed -n 's/^VERSION=//p' "$ROOT/scripts/sparkle-tools.txt")"
assert_contains "$(<"$ROOT/Package.swift")" "Sparkle.git\", exact: \"$want\"" "sparkle-tools.txt names the version Package.swift pins"
chk="$ROOT/.build/checkouts/Sparkle/Package.swift"
if [[ -f "$chk" ]]; then
  assert_contains "$(<"$chk")" "checksum = \"$(sed -n 's/^SHA256=//p' "$ROOT/scripts/sparkle-tools.txt")\"" "SHA256 equals SwiftPM's pinned checksum"
fi
ft="$ROOT/scripts/fetch-sparkle-tools.sh"
print -r -- junk > "$tmp/wrong.zip"
assert_fails "a download with the wrong checksum is refused" "$ft" "$tmp/tools" "$tmp/wrong.zip"
[[ ! -e "$tmp/tools/bin/sign_update" ]] && _pass || _fail "nothing is extracted before the check"
assert_eq "" "$(find "$tmp/tools" -type f -perm +111 2>/dev/null)" "nothing executable is left after a refusal"

# the extraction path, offline: a zip made here, with its own config naming its checksum
mkdir -p "$tmp/zsrc/bin" "$tmp/zsrc/other"
printf '#!/bin/sh\necho fake-sign-update\n' > "$tmp/zsrc/bin/sign_update"; chmod +x "$tmp/zsrc/bin/sign_update"
print -r -- x > "$tmp/zsrc/other/file"
(cd "$tmp/zsrc" && zip -q -r "$tmp/good.zip" bin other)
(cd "$tmp/zsrc" && zip -q -r "$tmp/nobin.zip" other)
conf_for() { printf 'VERSION=2.10.1\nSHA256=%s\n' "$(shasum -a 256 "$1" | cut -d' ' -f1)" > "$2" }
conf_for "$tmp/good.zip" "$tmp/good.conf"; conf_for "$tmp/nobin.zip" "$tmp/nobin.conf"
out="$(SPARKLE_TOOLS_CONF="$tmp/good.conf" "$ft" "$tmp/tools-good" "$tmp/good.zip")"; rc=$?
assert_eq 0 "$rc" "a zip that matches the checksum is extracted"
assert_eq "$tmp/tools-good/bin/sign_update" "$out" "the path of sign_update is printed"
assert_eq "fake-sign-update" "$("$out")" "the extracted file is the one from the zip, executable"
assert_eq "" "$(find "$tmp/tools-good" -mindepth 2 -type f -not -name sign_update)" "only sign_update is extracted"
SPARKLE_TOOLS_CONF="$tmp/good.conf" "$ft" "$tmp/tools-bad" "$tmp/wrong.zip" >/dev/null 2>&1
assert_eq 1 "$?" "a zip that does not match that config is refused"
assert_eq "" "$(find "$tmp/tools-bad" -type f -perm +111 2>/dev/null)" "nothing executable is left after the refusal"
assert_fails "a matching zip without bin/sign_update fails" env SPARKLE_TOOLS_CONF="$tmp/nobin.conf" "$ft" "$tmp/tools-nobin" "$tmp/nobin.zip"
assert_eq "" "$(find "$tmp/tools-nobin" -type f -perm +111 2>/dev/null)" "nothing executable is left when sign_update is missing"
# the real zip from the SwiftPM cache, when this machine has it
real=""
for z in ${(f)"$(find "$HOME/Library/Caches/org.swift.swiftpm" "$ROOT/.build" -name '*.zip' -size +1M 2>/dev/null)"}; do
  [[ "$(shasum -a 256 "$z" | cut -d' ' -f1)" == "$(sed -n 's/^SHA256=//p' "$ROOT/scripts/sparkle-tools.txt")" ]] && { real="$z"; break; }
done
if [[ -n "$real" ]]; then
  out="$("$ft" "$tmp/tools-real" "$real")"; rc=$?
  assert_eq 0 "$rc" "the real Sparkle zip from the SwiftPM cache is extracted"
  assert_ok "the real sign_update is executable" test -x "$out"
else
  print "note: Sparkle's zip is not in the SwiftPM cache here; the extraction path is covered by the synthetic zip"
fi

finish
