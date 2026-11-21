#!/bin/bash
# Waits until the live feed equals this release's appcast.xml. Only warns, never fails (the release is valid either
# way; the site is another repository).
#
# Usage: scripts/wait-for-site-feed.sh <appcast.xml> [--url <url>] [--deadline <seconds>] [--interval <seconds>]
#   defaults: https://lintelapp.com/appcast.xml, 600 seconds in total (a deadline, not a number of tries: each request
#   is bounded by --max-time 20 and counts against it), 30 seconds between tries.
# Environment SITE_REBUILD_REQUESTED=true means the website was asked to rebuild; any other value means it was not, which
# is said in a warning (the feed on the site then stays at the previous one until someone refreshes it by hand), and the
# poll still runs, because the site may rebuild by itself.
set -uo pipefail
FEED="${1:-}"
[[ -f "$FEED" ]] || { echo "usage: wait-for-site-feed.sh <appcast.xml> [--url U] [--deadline S] [--interval S]" >&2; exit 64; }
shift
URL="https://lintelapp.com/appcast.xml" DEADLINE=600 INTERVAL=30
while (( $# )); do
  case "$1" in
    --url) URL="${2:-}" ;;
    --deadline) DEADLINE="${2:-}" ;;
    --interval) INTERVAL="${2:-}" ;;
    *) echo "unknown option $1" >&2; exit 64 ;;
  esac
  shift 2 || exit 64
done
[[ "$DEADLINE" =~ ^[0-9]+$ && "$INTERVAL" =~ ^[0-9]+$ ]] || { echo "deadline and interval are whole seconds" >&2; exit 64; }
if [[ "${SITE_REBUILD_REQUESTED:-}" != true ]]; then
  echo "::warning::The website was not asked to rebuild (no LINTEL_WEB_DISPATCH_TOKEN, or the dispatch failed). The feed at ${URL} stays at the previous release's until lintel-web is rebuilt: redeploy it by hand (workflow_dispatch)."
fi
LIVE="$(mktemp)"
trap 'rm -f "$LIVE"' EXIT
START=$SECONDS
while :; do
  if curl -fsSL --max-time 20 -H 'Cache-Control: no-cache' -o "$LIVE" "$URL" 2>/dev/null && cmp -s "$LIVE" "$FEED"; then
    echo "$URL serves the new feed."
    exit 0
  fi
  (( SECONDS - START + INTERVAL < DEADLINE )) || break
  sleep "$INTERVAL"
done
echo "::warning::$URL still differs from this release's appcast.xml after $(( (DEADLINE + 59) / 60 )) minutes. The release is valid; check the lintel-web build (it is another repository) and redeploy it by hand if needed."
exit 0
