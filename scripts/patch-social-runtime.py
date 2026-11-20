#!/usr/bin/env python3
"""Apply reviewed provider patches to checksum-pinned Keraunos source.

TikTok's existing Referer behavior stays unchanged. YouTube's pinned
2026.10.26 yt-dlp must NOT be forced to obsolete player clients
(tv/tv_embedded/android_vr): upstream now selects tv_samsung, visionos and web
based on JavaScript-provider availability. Exact markers are asserted so a
future upstream source change cannot silently invalidate this fix.
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


# YouTube-specific repair: the old source overrides yt-dlp with three clients
# that no longer match the upstream 2026.10.26 default selection. tv/android_vr
# in particular can return HTTP 403 or no direct formats. The officially
# maintained per-release selection also respects the registered JSC provider.
old_client_arg = '        "extractor_args": {"youtube": {"player_client": ["tv", "tv_embedded", "android_vr"]}},\n'
if source.count(old_client_arg) != 2:
    raise SystemExit("Unexpected old YouTube client override layout; refusing to patch")
source = source.replace(old_client_arg, "")
if '"player_client": ["tv", "tv_embedded", "android_vr"]' in source:
    raise SystemExit("Obsolete YouTube client override remains")

# The provider is optional for non-YouTube pages, but we must never silently
# swallow an import error when debugging a failed YouTube request.
old_jsc = '''try:
    import keraunos_youtube_jsc  # noqa: F401  (registers the JS-challenge provider on import)
except Exception:
    pass   # fail open: extraction proceeds (YouTube n/sig unavailable without it)
'''
new_jsc = '''_YOUTUBE_JSC_IMPORT_FAILURE = None
try:
    import keraunos_youtube_jsc  # noqa: F401  (registers the JS-challenge provider on import)
except Exception as e:
    _YOUTUBE_JSC_IMPORT_FAILURE = type(e).__name__
    # Retain yt-dlp's jsless fallback. Diagnose, never fabricate a working JSC.
'''
if source.count(old_jsc) != 1:
    raise SystemExit("Unexpected YouTube JSC import layout; refusing to patch")
source = source.replace(old_jsc, new_jsc)

source_path.write_text(source, encoding="utf-8")
