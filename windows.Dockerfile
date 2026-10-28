# windows-x64 FFmpeg cross-compiled with mingw-w64 (static libgcc/winpthread, no DLLs next to the exe).
#   docker build -f tools/ffmpeg/windows.Dockerfile -t mmx-ffmpeg-windows tools/ffmpeg
#   docker run --rm -v "$PWD:/src" -w /src mmx-ffmpeg-windows tools/ffmpeg/build.sh windows-x64 dist
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      autoconf automake bash build-essential ca-certificates libtool curl gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix \
      binutils-mingw-w64-x86-64 mingw-w64-x86-64-dev nasm perl pkg-config python3 python3-venv xz-utils zip \
    && rm -rf /var/lib/apt/lists/*
