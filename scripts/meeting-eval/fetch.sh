#!/usr/bin/env bash
# Download a YouTube video's best audio as 16 kHz mono 16-bit PCM WAV,
# plus its automatic Polish captions as VTT.
#
# usage: fetch.sh <youtube-url> <output-dir> <name>
set -euo pipefail

usage() {
  echo "usage: $(basename "$0") <youtube-url> <output-dir> <name>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage

url="$1"
dir="$2"
name="$3"

mkdir -p "$dir"

# 1. Best audio, original container.
yt-dlp --no-playlist -f bestaudio -o "$dir/$name.%(ext)s" "$url"

# Locate the downloaded audio (anything named "<name>.*" that is not our output).
shopt -s nullglob
sources=()
for f in "$dir/$name".*; do
  case "$f" in
    *.wav|*.vtt) continue ;;
  esac
  sources+=("$f")
done
shopt -u nullglob

if [[ ${#sources[@]} -ne 1 ]]; then
  echo "error: expected exactly one downloaded audio file in $dir for $name, found ${#sources[@]}" >&2
  printf '  %s\n' "${sources[@]+"${sources[@]}"}" >&2
  exit 1
fi
src="${sources[0]}"

# 2. Convert to 16 kHz mono 16-bit PCM WAV.
wav="$dir/$name.wav"
ffmpeg -y -hide_banner -loglevel error -i "$src" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$wav"

# 3. Remove the intermediate audio.
rm -f -- "$src"

# 4. Polish auto captions as VTT (no media download).
yt-dlp --no-playlist --skip-download --write-auto-subs \
  --sub-langs "pl-orig,pl" --sub-format vtt \
  -o "$dir/$name.%(ext)s" "$url"

# 5. Report the WAV duration.
echo "wav: $wav"
echo "duration_seconds: $(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$wav")"
