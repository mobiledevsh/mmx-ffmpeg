#!/usr/bin/env bash
# Collects the Corresponding Source of the embedded FFmpeg for a release: the pinned source archive of FFmpeg and of
# every library linked into it (verified against versions.env), plus these build scripts, which LGPL-3.0 counts as part
# of the source ("scripts used to control compilation"). Build-only tools (automake, nasm) are left out: they are not
# distributed. Usage: tools/ffmpeg/sources.sh <out-dir>   (MMX_CACHE reuses archives build.sh already downloaded)
set -euo pipefail

mkdir -p "${1:?out-dir}"
OUT=$(cd "$1" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=versions.env
source "$HERE/versions.env"
CACHE=${MMX_CACHE:-}

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

LIST="$OUT/ffmpeg-$MMX_BUILD_ID-sources.txt"
{
  echo "Corresponding Source of the embedded FFmpeg $MMX_BUILD_ID (LGPL-3.0)."
  echo "Each archive below is the unmodified upstream release; ffmpeg-build-scripts-$MMX_BUILD_ID.tar.gz shows how they were built."
  echo
} > "$LIST"

for name in FFMPEG ZLIB OPUS LAME LIBVPX DAV1D LIBJXL HIGHWAY BROTLI LCMS2 ZIMG; do
  url_var="${name}_URL"; sum_var="${name}_SHA256"
  url=${!url_var}; sum=${!sum_var}
  file="$OUT/$(echo "$name" | tr '[:upper:]' '[:lower:]')-$(basename "$url")"
  cached="$CACHE/$(echo "$name" | tr '[:upper:]' '[:lower:]')-$(basename "$url")"
  if [ -n "$CACHE" ] && [ -f "$cached" ]; then cp "$cached" "$file"; else curl -fsSL --retry 3 -o "$file" "$url"; fi
  [ "$(sha256 "$file")" = "$sum" ] || { echo "Checksum mismatch for $url" >&2; exit 1; }
  echo "$(basename "$file")  $sum  $url" >> "$LIST"
done

tar -czf "$OUT/ffmpeg-build-scripts-$MMX_BUILD_ID.tar.gz" -C "$HERE/../.." tools/ffmpeg
echo "ffmpeg-build-scripts-$MMX_BUILD_ID.tar.gz  $(sha256 "$OUT/ffmpeg-build-scripts-$MMX_BUILD_ID.tar.gz")  tools/ffmpeg of this repository" >> "$LIST"
echo "Collected $(($(wc -l < "$LIST") - 3)) source archives in $OUT"
