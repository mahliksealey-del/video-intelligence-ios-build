#!/usr/bin/env python3
"""Offline contract smoke check for the exact Python included in the IPA.

Does NOT claim to contact YouTube or prove a download succeeds.
Verifies that both URL shapes use yt-dlp's supported default player clients
and that a working AVFoundation-compatible format is passed to native Swift.
"""
import json

import yt_dlp
import keraunos_extract as bridge
from yt_dlp.extractor.youtube._video import YoutubeIE

assert bridge._YOUTUBE_JSC_IMPORT_FAILURE is None, (
    "Bundled in-process EJS provider could not import: "
    + str(bridge._YOUTUBE_JSC_IMPORT_FAILURE)
)
assert "tv_samsung" in YoutubeIE._DEFAULT_CLIENTS
assert "visionos" in YoutubeIE._DEFAULT_CLIENTS
assert "web" in YoutubeIE._DEFAULT_CLIENTS
assert "android_vr" not in YoutubeIE._DEFAULT_CLIENTS

seen = []
regular = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
shorts = "https://www.youtube.com/shorts/dQw4w9WgXcQ"

formats = [
    {"format_id": "18", "url": "https://rr.googlevideo.com/one.mp4",
     "protocol": "https", "height": 360, "ext": "mp4",
     "vcodec": "avc1.42001e", "acodec": "mp4a.40.2", "tbr": 700},
    {"format_id": "22", "url": "https://rr.googlevideo.com/two.mp4",
     "protocol": "https", "height": 720, "ext": "mp4",
     "vcodec": "avc1.64001f", "acodec": "mp4a.40.2", "tbr": 2200},
]

class CapturingDownloader:
    def __init__(self, opts):
        seen.append(opts)
        assert "player_client" not in opts.get("extractor_args", {}).get("youtube", {}), (
            "A stale YouTube player-client override is still forced")
        assert opts.get("skip_download")
        assert "format" in opts

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def extract_info(self, url, download=False):
        assert url in (regular, shorts)
        assert not download
        return {"id": "dQw4w9WgXcQ", "title": "Contract Test",
                "url": formats[-1]["url"], "ext": "mp4",
                "vcodec": formats[-1]["vcodec"], "acodec": formats[-1]["acodec"],
                "protocol": "https", "formats": formats}

    def prepare_filename(self, info):
        return "Contract-Test.mp4"

real_ydl = yt_dlp.YoutubeDL
yt_dlp.YoutubeDL = CapturingDownloader
try:
    for url in (regular, shorts):
        result = json.loads(bridge._extract_impl(url, 15, None))
        assert result["ok"] and result["kind"] == "progressive", result
        assert result["media"]["url"] == formats[-1]["url"], result

        listed = json.loads(bridge._list_impl(url, 15, None))
        assert listed["ok"] and listed["kind"] == "choices", listed
        assert [option["height"] for option in listed["options"]] == [720, 360]
finally:
    yt_dlp.YoutubeDL = real_ydl

assert len(seen) == 4, len(seen)
print("YouTube extractor contract OK: regular + Shorts; no stale player-client override")
print("NOTE: Offline contract only; real YouTube HTTP download remains device-unverified")
