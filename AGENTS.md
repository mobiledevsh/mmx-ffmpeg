# Agent rules for mmx-ffmpeg

LGPL FFmpeg builds for the Multimedia plugin (internal name MMX; its private repository is `../mmx`). This repository
is **public**: never commit anything from the plugin's code, its keys or its users. Everything here may be read by
anyone, the history included.

- License: LGPL v3 only. Never `--enable-gpl`/`--enable-nonfree`, never a GPL or non-free library; `build.sh` and
  `check.sh` fail if one leaks in. The scripts themselves are MIT (`LICENSE`).
- Every release carries the Corresponding Source (`sources.sh`): the pinned upstream archives and the scripts at the
  tagged commit. Do not delete a release a plugin version points to.
- Bump `MMX_BUILD_ID` in `versions.env` whenever `versions.env` or `build.sh` changes: the ZIP names, the plugin's
  install directory and its "is this build current" check all go by it.
- `build.sh` is read while it runs: editing it breaks a running build. Build from a copy.
- macOS x64 on Apple silicon: `arch -x86_64 /bin/bash build.sh macos-x64 dist`. Linux and Windows in Docker
  (`linux.Dockerfile`, `windows.Dockerfile`, `--platform linux/amd64` for x64 on ARM); Docker Desktop's VM has about
  4 GB, so `MMX_JOBS=4` (libjxl runs out of memory at -j8).
- musl Linux builds need a 2 MB thread stack (`-Wl,-z,stack-size`), or FFmpeg crashes on MPEG-TS (`check.sh` tests it).
- The plugin relies on: libdav1d and libjxl decoders, `zscale` + `tonemap` (HDR → SDR), the `lavfi` input device,
  libvpx-vp9, libopus, libmp3lame, libjxl encoders. `check.sh` covers them; extend it when the plugin needs more.
- Shell is zsh on macOS: run the scripts with bash.
