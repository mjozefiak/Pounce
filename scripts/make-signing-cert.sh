#!/usr/bin/env bash
# Generate the stable self-signed "Pounce Release" code-signing certificate, import it
# into the login keychain, and (optionally) upload it to the repository's GitHub
# Actions secrets SIGNING_P12 and SIGNING_P12_PASSWORD.
#
# WARNING: regenerating the certificate changes Pounce's designated requirement.
# Every user loses Accessibility / Full Disk Access grants and Keychain access on the
# next update (see BACKWARD_COMPATIBILITY.md section 4). Only run this to create the
# identity for the first time, or as a deliberate, documented break.
#
# Usage: scripts/make-signing-cert.sh [--upload-secrets] [--repo owner/name]
# The private key and the .p12 password never leave a mktemp directory that is
# deleted on exit; nothing is printed or committed.
set -euo pipefail

IDENTITY="Pounce Release"
UPLOAD=0
REPO=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload-secrets) UPLOAD=1; shift ;;
    --repo) REPO="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

OPENSSL="${OPENSSL:-$(command -v /opt/homebrew/bin/openssl || command -v openssl)}"
if ! "$OPENSSL" version | grep -q '^OpenSSL 3'; then
  echo "OpenSSL 3 is required (brew install openssl@3, or set OPENSSL=)" >&2
  exit 1
fi

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "A certificate named \"$IDENTITY\" already exists in your keychains; refusing to create a second one." >&2
  exit 1
fi

umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

"$OPENSSL" req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

"$OPENSSL" rand -base64 33 | tr -d '\n' > "$WORK/pass.txt"

# Legacy PBE/MAC so that macOS `security import` accepts the bundle on every runner.
"$OPENSSL" pkcs12 -export -legacy -name "$IDENTITY" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/pounce.p12" -passout "file:$WORK/pass.txt"

security import "$WORK/pounce.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -f pkcs12 -P "$(cat "$WORK/pass.txt")" -T /usr/bin/codesign >/dev/null
echo "Imported \"$IDENTITY\" into the login keychain."

if [[ "$UPLOAD" == 1 ]]; then
  REPO_ARGS=()
  [[ -n "$REPO" ]] && REPO_ARGS=(--repo "$REPO")
  base64 < "$WORK/pounce.p12" | tr -d '\n' | gh secret set SIGNING_P12 "${REPO_ARGS[@]}"
  gh secret set SIGNING_P12_PASSWORD "${REPO_ARGS[@]}" < "$WORK/pass.txt"
  echo "Uploaded secrets SIGNING_P12 and SIGNING_P12_PASSWORD."
fi
echo "Certificate SHA-1: $("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1 | cut -d= -f2)"
