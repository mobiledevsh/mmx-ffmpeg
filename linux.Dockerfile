# Static (musl) FFmpeg for linux-x64 / linux-arm64: runs on any distribution, no shared libraries.
#   docker build -f linux.Dockerfile -t mmx-ffmpeg-linux .
#   docker run --rm -v "$PWD:/src" -w /src mmx-ffmpeg-linux ./build.sh linux-arm64 dist
FROM alpine:3.22
RUN apk add --no-cache bash build-base coreutils curl linux-headers nasm autoconf automake libtool perl pkgconf python3 tar xz zip diffutils
