#!/usr/bin/env python3
"""Apply a bounded TikTok-only Referer fix to checksum-pinned Keraunos source.

The upstream source is pinned by scripts/prepare-social-runtime.sh's archive SHA.
Refuse to patch when its expected function/layout markers drift.
"""
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
source = source_path.read_text(encoding="utf-8")
marker = "    if cookiefile and os.path.exists(cookiefile):\n"

if source.count(marker) != 2 or source.count("import threading\n") != 1:
    raise SystemExit("Unexpected Keraunos extraction code layout; refusing to patch")

source = source.replace(
    "import threading\n", "import threading\nfrom urllib.parse import urlsplit\n", 1
)
extra = (
    '    host = (urlsplit(url).hostname or "").lower()\n'
    '    if host == "tiktok.com" or host.endswith(".tiktok.com"):\n'
    '        opts["http_headers"] = {"Referer": "https://www.tiktok.com/"}\n'
)
source = source.replace(marker, extra + marker)
if source.count('opts["http_headers"] = {"Referer": "https://www.tiktok.com/"}') != 2:
    raise SystemExit("Scoped header injection failed")
source_path.write_text(source, encoding="utf-8")
