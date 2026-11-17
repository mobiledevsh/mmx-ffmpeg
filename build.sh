#!/usr/bin/env bash
# Builds the embedded FFmpeg of the Multimedia plugin (MMX): static, LGPL v3 only (no --enable-gpl, no --enable-nonfree),
# external libraries limited to permissive/LGPL ones (zlib, dav1d, opus, libvpx, LAME, libjxl with highway/brotli/lcms2,
# zimg for HDR tone mapping).
#
#   ./build.sh <platform> <out-dir>
#
#   macos-arm64, macos-x64   run natively on a Mac of that architecture, or macos-x64 under Rosetta on Apple
#                            silicon (arch -x86_64 ./build.sh ...); needs Xcode CLT, python3, autoconf,
#                            libtool; automake and nasm are built from pinned tarballs when missing
#   linux-x64, linux-arm64   run inside linux.Dockerfile (Alpine/musl → fully static binary)
#   windows-x64              run inside windows.Dockerfile (mingw-w64 cross build)
#
# Produces <out-dir>/ffmpeg-<build-id>-<platform>.zip (+ .sha256) with bin/ffmpeg, bin/ffprobe,
# the LGPL text and BUILDINFO.txt (exact configure line and source URLs, as the LGPL requires).
set -euo pipefail

PLATFORM=${1:?platform}
mkdir -p "${2:?out-dir}"
OUT=$(cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=versions.env
source "$HERE/versions.env"

WORK=${MMX_WORK:-$PWD/.ffbuild/$PLATFORM}
CACHE=${MMX_CACHE:-$PWD/.ffbuild/cache}
SRC=$WORK/src
PREFIX=$WORK/prefix
# MMX_JOBS caps parallelism: libjxl's C++ needs ~0.5 GB per compiler, more than Docker Desktop's default VM has at -j8.
JOBS=${MMX_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu)}
rm -rf "$SRC" "$PREFIX"
mkdir -p "$SRC" "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$CACHE"

# Only our prefix may satisfy pkg-config: never link Homebrew/distro libraries by accident.
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig

EXE=""
CROSS=""
HOST=""
CFLAGS="-O2"
LDFLAGS=""
VPX_TARGET=""
FFMPEG_PLATFORM=()
MESON_CROSS=()

case "$PLATFORM" in
  macos-arm64|macos-x64)
    ARCH=$([ "$PLATFORM" = macos-arm64 ] && echo arm64 || echo x86_64)
    [ "$(uname -m)" = "$ARCH" ] || { echo "Build $PLATFORM on a $ARCH Mac" >&2; exit 1; }
    export MACOSX_DEPLOYMENT_TARGET=11.0
    CFLAGS="$CFLAGS -arch $ARCH -mmacosx-version-min=11.0"
    LDFLAGS="-arch $ARCH -mmacosx-version-min=11.0"
    HOST=$([ "$ARCH" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
    VPX_TARGET=$([ "$ARCH" = arm64 ] && echo arm64-darwin20-gcc || echo x86_64-darwin20-gcc)
    export CC=clang CXX=clang++
    # macOS frameworks: hardware decode/encode (h264/hevc/prores_videotoolbox) and AAC/ALAC codecs.
    FFMPEG_PLATFORM=(--enable-videotoolbox --enable-audiotoolbox --enable-zlib)
    # Under Rosetta (macos-x64 on Apple silicon) python3 and thus meson may still be arm64 and would configure
    # dav1d for the wrong CPU: describe the target explicitly.
    if [ "$(python3 -c 'import platform; print(platform.machine())')" != "$ARCH" ]; then
      cat > "$WORK/meson-cross.ini" <<EOF
[binaries]
c = ['clang', '-arch', '$ARCH']
cpp = ['clang++', '-arch', '$ARCH']
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-mmacosx-version-min=11.0']
c_link_args = ['-arch', '$ARCH', '-mmacosx-version-min=11.0']
[host_machine]
system = 'darwin'
cpu_family = '$ARCH'
cpu = '$ARCH'
endian = 'little'
EOF
      MESON_CROSS=(--cross-file "$WORK/meson-cross.ini")
    fi
    ;;
  linux-x64|linux-arm64)
    ARCH=$([ "$PLATFORM" = linux-x64 ] && echo x86_64 || echo aarch64)
    [ "$(uname -m)" = "$ARCH" ] || { echo "Build $PLATFORM on a $ARCH Linux host" >&2; exit 1; }
    HOST=$ARCH-linux-musl
    VPX_TARGET=$([ "$ARCH" = x86_64 ] && echo x86_64-linux-gcc || echo arm64-linux-gcc)
    export CC=gcc CXX=g++
    LDFLAGS="-static"
    # musl gives threads 128 KB of stack; FFmpeg's demuxer threads overflow it on MPEG-TS (SIGSEGV).
    # musl takes the default thread stack size from PT_GNU_STACK, which -z stack-size sets.
    FFMPEG_PLATFORM=(--enable-zlib "--extra-ldexeflags=-static -Wl,-z,stack-size=2097152")
    ;;
  windows-x64)
    CROSS=x86_64-w64-mingw32-
    HOST=x86_64-w64-mingw32
    VPX_TARGET=x86_64-win64-gcc
    EXE=.exe
    export CC=${CROSS}gcc CXX=${CROSS}g++ AR=${CROSS}ar RANLIB=${CROSS}ranlib STRIP=${CROSS}strip
    # No libwinpthread/libgcc DLLs next to the exe; FORTIFY needs libssp, which mingw does not link statically.
    CFLAGS="$CFLAGS -D_FORTIFY_SOURCE=0"
    LDFLAGS="-static -static-libgcc"
    FFMPEG_PLATFORM=(--target-os=mingw32 --arch=x86_64 --cross-prefix=$CROSS --enable-cross-compile
      --enable-zlib --enable-mediafoundation --enable-d3d11va --enable-dxva2)
    cat > "$WORK/meson-cross.ini" <<EOF
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
windres = '${CROSS}windres'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
    MESON_CROSS=(--cross-file "$WORK/meson-cross.ini")
    ;;
  *) echo "Unknown platform $PLATFORM" >&2; exit 1 ;;
esac
# C++ libraries (zimg; CMake ones get CMAKE_OSX_ARCHITECTURES) need the same target flags, e.g. -arch under Rosetta.
CXXFLAGS="$CFLAGS"
export CFLAGS CXXFLAGS LDFLAGS

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# fetch <url> <sha256> <dir-name>: download once into the cache, verify, unpack into $SRC/<dir-name>
fetch() {
  local url=$1 sum=$2 name=$3 file
  file="$CACHE/$name-$(basename "$url")"
  [ -f "$file" ] || curl -fsSL --retry 3 -o "$file.part" "$url" && { [ -f "$file" ] || mv "$file.part" "$file"; }
  [ "$(sha256 "$file")" = "$sum" ] || { echo "Checksum mismatch for $url" >&2; rm -f "$file"; exit 1; }
  mkdir -p "$SRC/$name"
  tar -xf "$file" -C "$SRC/$name" --strip-components=1
}

# quiet <command...>: no output on success, the tail of the log on failure (plain >/dev/null hid compiler errors).
quiet() {
  "$@" > "$WORK/step.log" 2>&1 || { echo "FAILED: $*" >&2; tail -60 "$WORK/step.log" >&2; return 1; }
}

# meson/ninja/cmake come from a private venv so the host needs nothing but python3.
if ! command -v meson >/dev/null || ! command -v ninja >/dev/null || ! command -v cmake >/dev/null; then
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet meson==1.8.2 ninja==1.11.1.4 cmake==3.31.6
  export PATH=$WORK/venv/bin:$PATH
fi

# x86 assembly (FFmpeg, dav1d, libvpx) needs nasm; macOS does not ship it: build the pinned one.
case "$PLATFORM" in
  *-x64)
    if ! command -v nasm >/dev/null; then
      fetch "$NASM_URL" "$NASM_SHA256" nasm
      (cd "$SRC/nasm" && quiet ./configure --prefix="$WORK/tools" && quiet make -j"$JOBS" install)
      export PATH=$WORK/tools/bin:$PATH
    fi
    ;;
esac

# Static CMake builds into $PREFIX (highway, brotli, libjxl).
CMAKE_ARGS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_PREFIX_PATH="$PREFIX" -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF)
case "$PLATFORM" in
  macos-*) CMAKE_ARGS+=(-DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0) ;;
  windows-x64) CMAKE_ARGS+=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=x86_64
    -DCMAKE_C_COMPILER=${CROSS}gcc -DCMAKE_CXX_COMPILER=${CROSS}g++ -DCMAKE_RC_COMPILER=${CROSS}windres
    -DCMAKE_FIND_ROOT_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY) ;;
esac
cmake_install() {  # cmake_install <name> [extra -D options...]
  local name=$1; shift
  # Not "build": highway ships a Bazel BUILD file, which collides on case-insensitive file systems (macOS).
  quiet cmake -S "$SRC/$name" -B "$SRC/$name/_cmake" "${CMAKE_ARGS[@]}" "$@"
  quiet cmake --build "$SRC/$name/_cmake" -j"$JOBS"
  quiet cmake --install "$SRC/$name/_cmake"
}

echo "== zlib"
if [ "${PLATFORM%%-*}" != macos ]; then  # macOS: the system libz is part of the OS ABI
  fetch "$ZLIB_URL" "$ZLIB_SHA256" zlib
  if [ "$PLATFORM" = windows-x64 ]; then
    make -C "$SRC/zlib" -f win32/Makefile.gcc -j"$JOBS" PREFIX=$CROSS \
      BINARY_PATH="$PREFIX/bin" INCLUDE_PATH="$PREFIX/include" LIBRARY_PATH="$PREFIX/lib" install >/dev/null
  else
    (cd "$SRC/zlib" && ./configure --static --prefix="$PREFIX" >/dev/null && make -j"$JOBS" install >/dev/null)
  fi
fi

echo "== opus"
fetch "$OPUS_URL" "$OPUS_SHA256" opus
(cd "$SRC/opus" && ./configure --host="$HOST" --prefix="$PREFIX" --disable-shared --enable-static \
  --disable-doc --disable-extra-programs --disable-stack-protector >/dev/null && make -j"$JOBS" install >/dev/null)

echo "== lame"
fetch "$LAME_URL" "$LAME_SHA256" lame
# 3.100 exports a symbol it no longer defines; linkers on macOS refuse that.
sed -i.bak '/lame_init_old/d' "$SRC/lame/include/libmp3lame.sym"
(cd "$SRC/lame" && ./configure --host="$HOST" --prefix="$PREFIX" --disable-shared --enable-static \
  --disable-frontend --disable-gtktest >/dev/null && make -j"$JOBS" install >/dev/null)

echo "== libvpx"
fetch "$LIBVPX_URL" "$LIBVPX_SHA256" libvpx
(cd "$SRC/libvpx" && CROSS=$CROSS ./configure --target="$VPX_TARGET" --prefix="$PREFIX" \
  --disable-shared --enable-static --enable-pic --enable-vp9-highbitdepth \
  --disable-examples --disable-tools --disable-docs --disable-unit-tests >/dev/null && make -j"$JOBS" install >/dev/null)

echo "== dav1d"
fetch "$DAV1D_URL" "$DAV1D_SHA256" dav1d
quiet meson setup "$SRC/dav1d/build" "$SRC/dav1d" ${MESON_CROSS[@]+"${MESON_CROSS[@]}"} --prefix="$PREFIX" --libdir=lib \
  --default-library=static --buildtype=release -Denable_tools=false -Denable_tests=false -Denable_examples=false
quiet ninja -C "$SRC/dav1d/build" install

echo "== highway"
fetch "$HIGHWAY_URL" "$HIGHWAY_SHA256" highway
# contrib/ (thread pool, sort) is not used by libjxl and needs Windows SDK APIs mingw lacks.
cmake_install highway -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_INSTALL=ON -DHWY_ENABLE_CONTRIB=OFF

echo "== brotli"
fetch "$BROTLI_URL" "$BROTLI_SHA256" brotli
cmake_install brotli -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF

echo "== lcms2"
fetch "$LCMS2_URL" "$LCMS2_SHA256" lcms2
(cd "$SRC/lcms2" && ./configure --host="$HOST" --prefix="$PREFIX" --disable-shared --enable-static \
  --without-jpeg --without-tiff >/dev/null && make -j"$JOBS" install >/dev/null)

echo "== libjxl"
fetch "$LIBJXL_URL" "$LIBJXL_SHA256" libjxl
# The release tarball has no git submodules: use the libraries built above, lcms2 instead of skcms.
cmake_install libjxl -DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_LCMS2=ON \
  -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
  -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
  -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_VIEWERS=OFF -DJPEGXL_ENABLE_PLUGINS=OFF \
  -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_WARNINGS_AS_ERRORS=OFF
echo "== zimg"
fetch "$ZIMG_URL" "$ZIMG_SHA256" zimg
# GitHub tarballs carry no configure script. macOS has no automake by default: build the pinned one.
if ! command -v automake >/dev/null; then
  command -v autoconf >/dev/null || { echo "autoconf is required (macOS: brew install autoconf libtool)" >&2; exit 1; }
  fetch "$AUTOMAKE_URL" "$AUTOMAKE_SHA256" automake
  (cd "$SRC/automake" && quiet ./configure --prefix="$WORK/tools" && quiet make install)
  export PATH=$WORK/tools/bin:$PATH
fi
command -v libtoolize >/dev/null || ! command -v glibtoolize >/dev/null || export LIBTOOLIZE=glibtoolize  # Homebrew name
# A private automake does not search other prefixes for libtool.m4.
LIBTOOL_M4=$(dirname "$(dirname "$(command -v "${LIBTOOLIZE:-libtoolize}")")")/share/aclocal
export ACLOCAL_PATH=$LIBTOOL_M4${ACLOCAL_PATH:+:$ACLOCAL_PATH}
(cd "$SRC/zimg" && quiet autoreconf -fi && quiet ./configure --host="$HOST" --prefix="$PREFIX" \
  --disable-shared --enable-static && quiet make -j"$JOBS" install)

# libjxl and zimg are C++; their static .pc files do not name the C++ runtime.
case "$PLATFORM" in
  macos-*) CXX_RUNTIME=-lc++ ;;
  *) CXX_RUNTIME=-lstdc++ ;;
esac

echo "== ffmpeg"
fetch "$FFMPEG_URL" "$FFMPEG_SHA256" ffmpeg
CONFIGURE=(--prefix="$PREFIX/ffmpeg" --pkg-config=pkg-config --pkg-config-flags=--static
  --disable-gpl --disable-nonfree --enable-version3
  --disable-autodetect --disable-shared --enable-static --disable-debug --disable-doc --disable-ffplay
  # lavfi stays: MMX test-encodes with it (hardware encoder checks) and the test corpus is generated from it.
  --disable-network --disable-indevs --enable-indev=lavfi --disable-outdevs
  --enable-libdav1d --enable-libopus --enable-libvpx --enable-libmp3lame --enable-libjxl --enable-libzimg --extra-libs="$CXX_RUNTIME"
  --extra-version="${MMX_BUILD_ID#*-}"
  --extra-cflags="-I$PREFIX/include $CFLAGS" --extra-ldflags="-L$PREFIX/lib $LDFLAGS"
  "${FFMPEG_PLATFORM[@]}")
(cd "$SRC/ffmpeg" && ./configure "${CONFIGURE[@]}" > "$WORK/configure.log" 2>&1 || { tail -40 ffbuild/config.log; exit 1; })
quiet make -C "$SRC/ffmpeg" -j"$JOBS" install

echo "== package"
STAGE=$WORK/stage/ffmpeg-$MMX_BUILD_ID-$PLATFORM
rm -rf "$WORK/stage" && mkdir -p "$STAGE/bin"
for tool in ffmpeg ffprobe; do
  cp "$PREFIX/ffmpeg/bin/$tool$EXE" "$STAGE/bin/"
  ${CROSS}strip "$STAGE/bin/$tool$EXE" 2>/dev/null || strip "$STAGE/bin/$tool$EXE"
done
if [ "${PLATFORM%%-*}" = macos ]; then
  codesign --force --sign - "$STAGE/bin/ffmpeg" "$STAGE/bin/ffprobe"  # ad-hoc signature, required on arm64
fi
cp "$SRC/ffmpeg/COPYING.LGPLv3" "$STAGE/LICENSE.txt"
# BSD/MIT/Apache require their notices next to binaries: ship every library's license and patent files.
for lib in ffmpeg zlib opus lame libvpx dav1d highway brotli lcms2 libjxl zimg; do
  [ -d "$SRC/$lib" ] || continue
  mkdir -p "$STAGE/licenses/$lib"
  find "$SRC/$lib" -maxdepth 1 -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'PATENTS*' -o -iname 'AUTHORS' \) \
    -exec cp {} "$STAGE/licenses/$lib/" \;
done
{
  echo "MMX embedded FFmpeg $MMX_BUILD_ID for $PLATFORM"
  echo "License: LGPL-3.0-or-later (FFmpeg built with --enable-version3, without --enable-gpl/--enable-nonfree)"
  echo "Built: $(date -u +%Y-%m-%dT%H:%M:%SZ) by build.sh of github.com/mobiledevsh/mmx-ffmpeg"
  echo
  echo "Sources (verified by SHA-256):"
  grep -E '_(URL|SHA256)=' "$HERE/versions.env" | sed 's/^/  /'
  echo
  echo "FFmpeg configure:"
  printf '  %q\n' "${CONFIGURE[@]}"
} > "$STAGE/BUILDINFO.txt"

if [ -z "$CROSS" ]; then
  VERSION_OUT=$("$STAGE/bin/ffmpeg" -hide_banner -version)
  if grep -qE -- '--enable-(gpl|nonfree)' <<<"$VERSION_OUT"; then echo "GPL/nonfree leaked into the build" >&2; exit 1; fi
  "$STAGE/bin/ffprobe" -hide_banner -version | sed -n 1p  # not head: SIGPIPE + pipefail
  DECODERS=$("$STAGE/bin/ffmpeg" -hide_banner -decoders)  # not piped into grep -q: SIGPIPE + pipefail
  for codec in libdav1d libjxl; do
    grep -qw "$codec" <<<"$DECODERS" || { echo "$codec decoder missing" >&2; exit 1; }
  done
  FILTERS=$("$STAGE/bin/ffmpeg" -hide_banner -filters)
  for filter in zscale tonemap; do  # HDR → SDR tone mapping in previews and exports
    grep -qw "$filter" <<<"$FILTERS" || { echo "$filter filter missing" >&2; exit 1; }
  done
  # Demuxing runs in its own thread: catches too-small thread stacks (musl) that crash on MPEG-TS.
  TS=$WORK/check.ts
  "$STAGE/bin/ffmpeg" -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=320x240:d=1 -f lavfi -i sine=d=1 \
    -c:v mpeg2video -c:a mp2 -f mpegts "$TS"
  "$STAGE/bin/ffmpeg" -hide_banner -loglevel error -i "$TS" -f null - || { echo "decoding MPEG-TS crashes" >&2; exit 1; }
  DEVICES=$("$STAGE/bin/ffmpeg" -hide_banner -devices)
  grep -qw lavfi <<<"$DEVICES" || { echo "lavfi input device missing" >&2; exit 1; }
fi

ZIP=$OUT/ffmpeg-$MMX_BUILD_ID-$PLATFORM.zip
rm -f "$ZIP"
(cd "$WORK/stage" && zip -qr -X "$ZIP" "ffmpeg-$MMX_BUILD_ID-$PLATFORM")
sha256 "$ZIP" > "$ZIP.sha256"
echo "Built $ZIP ($(du -h "$ZIP" | cut -f1)) sha256=$(cat "$ZIP.sha256")"
