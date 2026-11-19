#!/bin/zsh
# Usage: scripts/stamp-version.sh <Info.plist> <version> <build>
# Writes CFBundleShortVersionString (<version>: X.Y.Z or X.Y.Z-beta.N) and CFBundleVersion (<build>: a plain positive
# integer) into <Info.plist>, then reads both back and fails when either differs. Run it on the COPY of the plist
# inside the built bundle, before any codesign: a stamp after signing breaks the signature. Never run it on
# Resources/Info.plist (scripts/make-app.sh copies it first). Exits 64 on a bad argument, 1 on a read-back mismatch.
set -euo pipefail

plist="${1:-}" version="${2:-}" build="${3:-}"
if [[ -z "$plist" || ! -f "$plist" ]]; then
  echo "Usage: stamp-version.sh <Info.plist> <version> <build>; no such file: '$plist'" >&2
  exit 64
fi
if [[ ! "$version" =~ '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.[1-9][0-9]*)?$' ]]; then
  echo "APP_VERSION must be X.Y.Z or X.Y.Z-beta.N, got: '$version'" >&2
  exit 64
fi
if [[ ! "$build" =~ '^[1-9][0-9]*$' ]]; then
  echo "APP_BUILD must be a plain positive integer, got: '$build'" >&2
  exit 64
fi

pb=/usr/libexec/PlistBuddy
"$pb" -c "Set :CFBundleShortVersionString $version" "$plist" >/dev/null
"$pb" -c "Set :CFBundleVersion $build" "$plist" >/dev/null

got_version="$("$pb" -c 'Print :CFBundleShortVersionString' "$plist")"
got_build="$("$pb" -c 'Print :CFBundleVersion' "$plist")"
if [[ "$got_version" != "$version" ]]; then
  echo "Version stamp mismatch: CFBundleShortVersionString is '$got_version', expected '$version'" >&2
  exit 1
fi
if [[ "$got_build" != "$build" ]]; then
  echo "Version stamp mismatch: CFBundleVersion is '$got_build', expected '$build'" >&2
  exit 1
fi
