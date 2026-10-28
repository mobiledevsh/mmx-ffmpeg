# Embedded FFmpeg

MMX runs FFmpeg as a child process. Which binary it uses is chosen in **Settings | Tools | Multimedia**:

| Mode | Uses |
|---|---|
| Automatic (default) | FFmpeg on the system (`PATH`, Homebrew, `/usr/local`, `C:\ffmpeg`, Scoop, Chocolatey, WinGet), otherwise the embedded build |
| System | only FFmpeg found on the system |
| Embedded | only the build from this directory: bundled into the plugin ZIP, or downloaded on demand |
| Custom | an `ffmpeg` executable, or a folder containing `ffmpeg` + `ffprobe` (or their `bin/`) |

`MMX_FFMPEG=/path/to/ffmpeg` overrides the mode; CI uses it to pin the build under test.

## License

The build is **LGPL v3** (`--enable-version3`, never `--enable-gpl` / `--enable-nonfree`; `build.sh` fails if
they leak in). External libraries are permissive or LGPL: zlib, dav1d (AV1 decoding), Opus, libvpx (VP8/VP9),
LAME (MP3) and libjxl (JPEG XL; BSD-3-Clause with Google's patent grant) with its dependencies highway
(Apache-2.0 or BSD-3-Clause), brotli (MIT) and lcms2 (MIT), and zimg (WTFPL) for HDR → SDR tone mapping
(`zscale` filter). FFmpeg has no JPEG XL decoder of its own — only the `jpegxl_pipe`/`jpegxl_anim` demuxers — so
`.jxl` needs libjxl. libplacebo (GPU tone mapping) is left out: it needs a Vulkan loader, glslang/shaderc and
MoltenVK; MMX uses it when the system FFmpeg has it. There is no x264/x265: MMX encodes H.264/HEVC with VideoToolbox on macOS and Media Foundation on
Windows; on Linux the embedded build offers VP9/WebM, ProRes, GIF and the audio formats instead.

Every archive contains `LICENSE.txt` (LGPL v3), `licenses/<library>/` (license, copying and patent files of every
library linked in — BSD, MIT and Apache require these notices next to the binary) and `BUILDINFO.txt` (source URLs
with SHA-256 and the exact configure line). The release itself carries the Corresponding Source:
`sources.sh` collects the verified upstream archives of FFmpeg and every linked library plus these scripts, and the
`ffmpeg.yml` workflow attaches them to each `ffmpeg-*` release (`tools/ffmpeg/sources.sh <out-dir>` to do it by hand;
`MMX_CACHE` reuses what `build.sh` downloaded). LGPL-3.0 makes the distributor keep that source available, so it is
published next to the binaries rather than only linked to upstream.

Patents are a separate question from copyright licenses: decoders for H.264, HEVC, AAC, AC-3 and others are
LGPL code, but those formats are patent-encumbered in some jurisdictions. This is not legal advice; if it
matters for your distribution, remove the decoders in `build.sh` (`--disable-decoder=...`).

## Building

```bash
# macOS (needs Xcode command line tools, python3, autoconf and libtool — brew install autoconf libtool;
# pinned automake and nasm are built when missing)
tools/ffmpeg/build.sh macos-arm64 dist
arch -x86_64 tools/ffmpeg/build.sh macos-x64 dist    # Intel build on Apple silicon, through Rosetta

# Linux, fully static (musl), runs on any distribution
docker build -f tools/ffmpeg/linux.Dockerfile -t mmx-ffmpeg-linux tools/ffmpeg
docker run --rm -e MMX_JOBS=4 -v "$PWD:/src" -w /src mmx-ffmpeg-linux tools/ffmpeg/build.sh linux-arm64 dist   # or linux-x64 on x86
# linux-x64 on Apple silicon: the same with --platform linux/amd64 for both docker build and docker run (emulated, slower)

# Windows x64, cross-compiled with mingw-w64
docker build -f tools/ffmpeg/windows.Dockerfile -t mmx-ffmpeg-windows tools/ffmpeg
docker run --rm -e MMX_JOBS=4 -v "$PWD:/src" -w /src mmx-ffmpeg-windows tools/ffmpeg/build.sh windows-x64 dist
```

`MMX_JOBS` caps parallel compilers: libjxl's C++ needs about 0.5 GB per compiler, and Docker Desktop's default VM
(4 GB) runs out of memory at `-j8` — the compiler is killed and the build stops. `MMX_WORK`/`MMX_CACHE` move the
build directory and the source cache (default `.ffbuild/`). Failed steps print the tail of their log.

Result: `dist/ffmpeg-<build-id>-<platform>.zip` and `.sha256`. Versions and checksums of all sources are pinned
in `versions.env`; bump `MMX_BUILD_ID` whenever it or `build.sh` changes.

CI (`.github/workflows/ffmpeg.yml`) builds all five platforms, then runs the complete test suite on each of
them with the fresh build. Pushing a tag `ffmpeg-<build-id>` publishes the ZIPs to a GitHub release together
with `ffmpeg-manifest.json`.

## Shipping it with the plugin

Two ways, combinable:

1. **Download on demand (default).** Commit the release's manifest as
   `shared/src/main/resources/mmx/ffmpeg-manifest.json`
   (`tools/ffmpeg/make_manifest.py dist <release-url> > shared/src/main/resources/mmx/ffmpeg-manifest.json`).
   The plugin stays small; the editor banner and the settings page offer "Download", which fetches the archive for
   the current platform through the IDE's proxy settings, verifies its SHA-256 and unpacks it into
   `<IDE system dir>/mmx-ffmpeg/<build-id>/<platform>`. In split mode the backend host downloads its own copy.
2. **Bundled.** `./gradlew buildPlugin -Pmmx.ffmpegDist=dist -Pmmx.bundleFfmpeg=all` (or `current`, or a list such
   as `macos-arm64,windows-x64`) puts the binaries into `<plugin>/ffmpeg/<platform>/bin`. All five platforms add
   roughly 5× the archive size to the plugin; useful for offline/air-gapped distribution.

For networks without GitHub access, host the ZIPs and a manifest on an internal server and set
**Embedded build manifest URL** in the settings (or `MMX_FFMPEG_MANIFEST`).

## The most complete FFmpeg from Homebrew (for local use)

Homebrew's own `ffmpeg` has a fixed feature set (no JPEG XL, zimg, libplacebo…). The
[homebrew-ffmpeg](https://github.com/homebrew-ffmpeg/homebrew-ffmpeg) tap builds it from source with options:

```bash
brew uninstall --ignore-dependencies ffmpeg        # the tap's formula replaces the core one
brew tap homebrew-ffmpeg/ffmpeg
brew install zvbi                                  # --with-libzvbi does not pull it in: configure fails otherwise
brew install homebrew-ffmpeg/ffmpeg/ffmpeg \
  --with-jpeg-xl --with-zimg --with-libplacebo --with-webp --with-openjpeg --with-openapv \
  --with-rav1e --with-openh264 --with-xvid --with-two-lame --with-opencore-amr \
  --with-libopenmpt --with-game-music-emu --with-libsoxr --with-rubberband \
  --with-librsvg --with-dvd --with-libvidstab --with-libvmaf --with-chromaprint \
  --with-libzvbi --with-libaribcaption --with-srt --with-librist --with-libssh --with-libxml2
# chromaprint depends on the core formula and reinstalls it: link the tap's build over it
brew unlink ffmpeg && brew link --overwrite homebrew-ffmpeg/ffmpeg/ffmpeg
ffmpeg -hide_banner -decoders | grep -E 'libjxl|libdav1d'   # check
```

Left out on purpose: `--with-decklink` and `--with-openssl` (make the build **non-free**, not redistributable;
DeckLink also needs Blackmagic's SDK), `--with-tensorflow`, `--with-openvino`, `--with-ggml`, `--with-tesseract`
(heavy ML/OCR stacks), `--with-jack` (needs a JACK server). `brew options homebrew-ffmpeg/ffmpeg/ffmpeg` lists
everything. The result is GPL (x264/x265 are included by default) — fine on your machine, not for redistribution;
MMX shows the license of whichever FFmpeg it uses in its settings.
