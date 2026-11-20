#!/bin/zsh
# The only place that hands the Sparkle EdDSA private key to `sign_update`.
#
# Usage: scripts/sparkle-sign.sh <command> [args]
#   check-key <Info.plist>   signs a small file with the key and verifies the signature against SUPublicEDKey from
#                            that Info.plist (CryptoKit, scripts/ed25519.swift). Exit 1 when the key does not belong to the
#                            public key the app ships with: an app built with this plist would refuse every update.
#   sign-file <file>         prints the file's EdDSA signature (base64) and nothing else
#   sign-feed <appcast.xml>  embeds the feed signature at the end of the file (bytes before it stay as they are)
#   verify-feed <appcast.xml> exit 0 when the embedded feed signature is valid for this key
# Environment:
#   SPARKLE_ED_PRIVATE_KEY   the private key (base64 of the 32-byte seed): the release Environment's secret
#   SPARKLE_SIGN_UPDATE      path of the sign_update binary (scripts/fetch-sparkle-tools.sh puts it in place)
#
# The key reaches sign_update on its standard input only (`--ed-key-file -`): never in an argument, never in a file.
# sign_update's own output is captured and never shown, because for a malformed key it quotes the key. This script
# prints fixed messages only. Do not run it with `set -x`.
set -uo pipefail

CMD="${1:-}"
ARG="${2:-}"
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-}"
HERE="${0:A:h}"

fail() { print -u2 -r -- "::error::$1"; exit "${2:-1}"; }

[[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || fail "SPARKLE_ED_PRIVATE_KEY is not set." 64
[[ -x "$SIGN_UPDATE" ]] || fail "SPARKLE_SIGN_UPDATE does not name an executable." 64
[[ -n "$ARG" ]] || fail "usage: sparkle-sign.sh check-key|sign-file|sign-feed|verify-feed <file>" 64

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
trap 'exit 130' INT TERM HUP

# Runs sign_update with the key on stdin. Its output goes to $TMP/out and $TMP/err, never to the log.
run_sign_update() {
  print -rn -- "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$@" > "$TMP/out" 2> "$TMP/err"
}

case "$CMD" in
  check-key)
    PLIST="$ARG"
    PUBLIC_KEY="$(plutil -extract SUPublicEDKey raw "$PLIST" 2>/dev/null)" || fail "SUPublicEDKey is missing in $PLIST."
    [[ -n "$PUBLIC_KEY" ]] || fail "SUPublicEDKey is empty in $PLIST."
    head -c 64 /dev/urandom | base64 > "$TMP/probe"
    run_sign_update -p "$TMP/probe" || fail "sign_update could not use SPARKLE_ED_PRIVATE_KEY (is it the base64 private key exported by generate_keys -x?)."
    SIGNATURE="$(<"$TMP/out")"
    [[ "$SIGNATURE" =~ '^[A-Za-z0-9+/]{20,}={0,2}$' ]] || fail "sign_update returned no signature."
    if ! swift "$HERE/ed25519.swift" verify "$PUBLIC_KEY" "$TMP/probe" "$SIGNATURE" >/dev/null 2>&1; then
      fail "SPARKLE_ED_PRIVATE_KEY does not belong to SUPublicEDKey in $PLIST. Nothing was published. Fix the secret or the public key before releasing: an app with this public key would reject updates signed by this key."
    fi
    print -r -- "The Sparkle signing key matches SUPublicEDKey in $PLIST."
    ;;
  sign-file)
    [[ -f "$ARG" ]] || fail "no file $ARG" 64
    run_sign_update -p "$ARG" || fail "sign_update failed to sign $ARG."
    SIGNATURE="$(<"$TMP/out")"
    [[ "$SIGNATURE" =~ '^[A-Za-z0-9+/]{20,}={0,2}$' ]] || fail "sign_update returned no signature."
    print -r -- "$SIGNATURE"
    ;;
  sign-feed)
    [[ -f "$ARG" ]] || fail "no file $ARG" 64
    # --disable-signing-warning keeps the file as written; without it sign_update re-serializes the XML.
    run_sign_update --disable-signing-warning "$ARG" || fail "sign_update failed to sign the feed."
    ;;
  verify-feed)
    [[ -f "$ARG" ]] || fail "no file $ARG" 64
    run_sign_update --verify "$ARG" || fail "the feed signature of $ARG is missing or does not verify against the Sparkle key."
    ;;
  *)
    fail "unknown command '$CMD'" 64
    ;;
esac
