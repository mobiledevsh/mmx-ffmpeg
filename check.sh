#!/usr/bin/env bash
# Checks an unpacked build on the system it is meant for (CI runs it on every platform, Windows included, whose
# binaries build.sh cross-compiles and cannot run): the license, the libraries and filters the plugin relies on, and
# an encode/decode round trip with every external encoder.
#
#   ./check.sh <unpacked build dir, the one with bin/>
set -euo pipefail

BIN=${1:?unpacked build dir}/bin
EXE=""
[ -f "$BIN/ffmpeg.exe" ] && EXE=.exe
FF="$BIN/ffmpeg$EXE"
FP="$BIN/ffprobe$EXE"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

VERSION=$("$FF" -hide_banner -version)  # not piped into grep -q / head: SIGPIPE + pipefail
sed -n 1p <<<"$VERSION"
"$FP" -hide_banner -version | sed -n 1p
if grep -qE -- '--enable-(gpl|nonfree)' <<<"$VERSION"; then fail "GPL/nonfree build"; fi
grep -q -- '--enable-version3' <<<"$VERSION" || fail "not built as LGPL v3 (--enable-version3)"

DECODERS=$("$FF" -hide_banner -decoders)
for codec in libdav1d libjxl; do grep -qw "$codec" <<<"$DECODERS" || fail "$codec decoder missing"; done
FILTERS=$("$FF" -hide_banner -filters)
for filter in zscale tonemap; do grep -qw "$filter" <<<"$FILTERS" || fail "$filter filter missing"; done

V=(-f lavfi -i testsrc2=s=320x240:r=25:d=1)
A=(-f lavfi -i sine=f=440:d=1)
# Encodes into $T/<name> with the given arguments, then decodes the result completely.
roundtrip() {
  local name=$1; shift
  "$FF" -hide_banner -loglevel error -y "$@" "$T/$name" || fail "encoding $name"
  "$FF" -hide_banner -loglevel error -i "$T/$name" -f null - || fail "decoding $name"
  echo "ok  $name"
}
roundtrip vp9-opus.webm "${V[@]}" "${A[@]}" -c:v libvpx-vp9 -deadline realtime -c:a libopus
roundtrip lame.mp3 "${A[@]}" -c:a libmp3lame
roundtrip aac.m4a "${A[@]}" -c:a aac
roundtrip flac.flac "${A[@]}" -c:a flac
roundtrip prores.mov "${V[@]}" -c:v prores_ks
roundtrip picture.png "${V[@]}" -frames:v 1 -update 1
roundtrip picture.jxl "${V[@]}" -frames:v 1 -c:v libjxl -f image2 -update 1
roundtrip animation.gif "${V[@]}" -t 0.2
# Demuxing runs in its own thread: a too-small thread stack (musl) crashes on MPEG-TS.
roundtrip stream.ts "${V[@]}" "${A[@]}" -c:v mpeg2video -c:a mp2 -f mpegts

# HDR → SDR as the plugin does it in software (zimg).
"$FF" -hide_banner -loglevel error -f lavfi -i testsrc2=s=320x240:d=0.2 \
  -vf "setparams=color_primaries=bt2020:color_trc=smpte2084:colorspace=bt2020nc,zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable,zscale=t=bt709:m=bt709:r=tv,format=yuv420p" \
  -f null - || fail "HDR tone mapping"
echo "ok  zscale + tonemap"
echo "All checks passed"
