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


# YouTube format-safety repair: the old broad [protocol^=http] selector includes
# yt-dlp's 'http_dash_segments' entries. Their 'url' is only a fragment/base
# endpoint; Video Intelligence's native HTTP downloader does not receive the
# yt-dlp 'fragments' list, so downloading that URL alone cannot produce a
# valid MP4. Use only direct HTTPS for YouTube, leaving all OTHER providers
# exactly as before. This deliberately does not claim HLS/SABR support.
youtube_helper = '''def _is_youtube_url(url):
    hostname = (urlsplit(url).hostname or "").lower()
    return hostname in ("youtube.com", "youtu.be", "youtube-nocookie.com") or (
        hostname.endswith(".youtube.com") or hostname.endswith(".youtube-nocookie.com")
    )


def _native_supported_format(fmt, url):
    return fmt.replace("protocol^=http", "protocol=https") if _is_youtube_url(url) else fmt


'''
anchor = 'def _is_http(fmt):\n'
if source.count(anchor) != 1:
    raise SystemExit("Missing yt-dlp HTTP format helper marker")
source = source.replace(anchor, youtube_helper + anchor)
old_extract_format = '"format": fmt,'
old_list_format = '"format": _FORMAT,'
if source.count(old_extract_format) != 1 or source.count(old_list_format) != 1:
    raise SystemExit("Unexpected YouTube format opts layout")
source = source.replace(old_extract_format, '"format": _native_supported_format(fmt, url),')
source = source.replace(old_list_format, '"format": _native_supported_format(_FORMAT, url),')
old_options = 'options = _muxable_height_options(info.get("formats") or [])'
new_options = '''candidate_formats = info.get("formats") or []
            if _is_youtube_url(url):
                # A DASH fragments descriptor is NOT a direct downloadable URL.
                candidate_formats = [f for f in candidate_formats
                                     if f.get("protocol") == "https"]
            options = _muxable_height_options(candidate_formats)'''
if source.count(old_options) != 1:
    raise SystemExit("Unexpected yt-dlp format-options layout")
source = source.replace(old_options, new_options)

source_path.write_text(source, encoding="utf-8")
