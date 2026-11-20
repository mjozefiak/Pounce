source "${0:A:h}/lib.zsh"
source "$ROOT/scripts/select-entitlements.sh"

team="$(<"$FIXTURES/codesign-teamid.txt")"
adhoc="$(<"$FIXTURES/codesign-adhoc.txt")"

assert_eq "$ROOT/Resources/Lintel.entitlements" "$(select_entitlements "$team")" "Team ID picks Lintel.entitlements"
assert_eq "$ROOT/Resources/Lintel-adhoc.entitlements" "$(select_entitlements "$adhoc")" "no Team ID picks the ad-hoc file"
assert_eq "--timestamp" "$(signing_timestamp_arg "$team")" "Team ID gets the secure timestamp"
assert_eq "--timestamp=none" "$(signing_timestamp_arg "$adhoc")" "no Team ID keeps --timestamp=none"
assert_fails "text without a TeamIdentifier line is refused" select_entitlements "Identifier=x"
assert_fails "empty text is refused" signing_timestamp_arg ""
assert_fails "an empty TeamIdentifier value is refused" select_entitlements "TeamIdentifier="

# The command line front end gives the same answers.
sel="$ROOT/scripts/select-entitlements.sh"
assert_eq "$ROOT/Resources/Lintel.entitlements" "$(zsh "$sel" < "$FIXTURES/codesign-teamid.txt")" "CLI: Team ID"
assert_eq "--timestamp" "$(zsh "$sel" --timestamp < "$FIXTURES/codesign-teamid.txt")" "CLI: Team ID timestamp"
assert_eq "--timestamp=none" "$(zsh "$sel" --timestamp < "$FIXTURES/codesign-adhoc.txt")" "CLI: ad-hoc timestamp"
assert_eq "$ROOT/Resources/Lintel-adhoc.entitlements" "$(zsh "$sel" --identity -)" "CLI: --identity - is ad-hoc"

# The two files differ exactly by disable-library-validation; both keep audio-input.
key=com.apple.security.cs.disable-library-validation
audio=com.apple.security.device.audio-input
pb=/usr/libexec/PlistBuddy
assert_fails "Lintel.entitlements has no $key" "$pb" -c "Print :$key" "$ROOT/Resources/Lintel.entitlements"
assert_ok "Lintel-adhoc.entitlements has $key" "$pb" -c "Print :$key" "$ROOT/Resources/Lintel-adhoc.entitlements"
assert_ok "Lintel.entitlements keeps audio-input" "$pb" -c "Print :$audio" "$ROOT/Resources/Lintel.entitlements"
assert_ok "Lintel-adhoc.entitlements keeps audio-input" "$pb" -c "Print :$audio" "$ROOT/Resources/Lintel-adhoc.entitlements"
assert_ok "both entitlements files are valid plists" plutil -lint "$ROOT/Resources/Lintel.entitlements" "$ROOT/Resources/Lintel-adhoc.entitlements"
# Same keys apart from the one: compare the key sets with the one removed.
keys_a="$(plutil -convert json -o - "$ROOT/Resources/Lintel.entitlements" | tr ',' '\n' | sort)"
keys_b="$(plutil -convert json -o - "$ROOT/Resources/Lintel-adhoc.entitlements" | tr ',' '\n' | grep -v disable-library-validation | sort)"
assert_eq "$(print -r -- "$keys_a" | tr -d '{}')" "$(print -r -- "$keys_b" | tr -d '{}')" "the files differ only by disable-library-validation"

# A real ad-hoc probe yields "TeamIdentifier=not set" and the ad-hoc file.
dv="$(probe_signing_identity -)"
assert_eq "$ROOT/Resources/Lintel-adhoc.entitlements" "$(select_entitlements "$dv")" "a real ad-hoc probe picks the ad-hoc file"
assert_eq "--timestamp=none" "$(signing_timestamp_arg "$dv")" "a real ad-hoc probe gets --timestamp=none"
finish
