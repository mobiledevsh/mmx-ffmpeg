#!/usr/bin/env python3
"""Writes the plugin's embedded FFmpeg manifest from build.sh outputs.

    tools/ffmpeg/make_manifest.py <dist-dir> <base-url> > shared/src/main/resources/mmx/ffmpeg-manifest.json

<base-url> is where the ZIPs are published, e.g. https://github.com/<owner>/<repo>/releases/download/ffmpeg-9.0.2-mmx1
"""
import json
import os
import re
import sys

dist, base = sys.argv[1], sys.argv[2].rstrip("/")
build_id = re.search(r"^MMX_BUILD_ID=(.+)$", open(os.path.join(os.path.dirname(__file__), "versions.env")).read(), re.M).group(1)
platforms = {}
for name in sorted(os.listdir(dist)):
    m = re.fullmatch(rf"ffmpeg-{re.escape(build_id)}-(.+)\.zip", name)
    if not m:
        continue
    path = os.path.join(dist, name)
    sha = open(path + ".sha256").read().split()[0]
    platforms[m.group(1)] = {"url": f"{base}/{name}", "sha256": sha, "size": os.path.getsize(path)}
if not platforms:
    sys.exit(f"no ffmpeg-{build_id}-*.zip in {dist}")
json.dump({"buildId": build_id, "license": "LGPL-3.0-or-later", "platforms": platforms}, sys.stdout, indent=2)
print()
