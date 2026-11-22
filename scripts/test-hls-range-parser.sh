#!/bin/bash
# Compile and run the native HLS RFC-8216 byte-range parser independently
# on the CI macOS host. No network, simulator, or user media is needed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/VideoIntelligenceNative/MediaProcessing/HLSRemux"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/hls_parser_check.c" <<'EOF'
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "m3u8.h"
#include "hls2mp4.h"

int main(void) {
    const char *vod =
        "#EXTM3U\n"
        "#EXT-X-TARGETDURATION:5\n"
        "#EXTINF:4,\n"
        "#EXT-X-BYTERANGE:1880@0\n"
        "media.ts\n"
        "#EXTINF:4,\n"
        "#EXT-X-BYTERANGE:3760\n"
        "media.ts\n"
        "#EXTINF:4,\n"
        "#EXT-X-BYTERANGE:1880@10240\n"
        "other.ts\n"
        "#EXT-X-ENDLIST\n";
    M3U8Playlist plan = {0};
    int status = m3u8_parse(vod, strlen(vod),
        "https://video.example.com/path/list.m3u8", &plan);
    assert(status == HLS2MP4_OK);
    assert(plan.is_vod == 1 && plan.count == 3);
    assert(plan.segments[0].range_start == 0);
    assert(plan.segments[0].range_length == 1880);
    assert(plan.segments[1].range_start == 1880);
    assert(plan.segments[1].range_length == 3760);
    assert(plan.segments[2].range_start == 10240);
    assert(plan.segments[2].range_length == 1880);
    m3u8_free(&plan);

    const char *invalid =
        "#EXTM3U\n"
        "#EXTINF:3,\n#EXT-X-BYTERANGE:100@0\nfirst.ts\n"
        "#EXTINF:3,\n#EXT-X-BYTERANGE:100\nsecond.ts\n"
        "#EXT-X-ENDLIST\n";
    M3U8Playlist bad = {0};
    status = m3u8_parse(invalid, strlen(invalid),
        "https://video.example.com/path/list.m3u8", &bad);
    assert(status == HLS2MP4_ERR_PARSE);
    m3u8_free(&bad);
    puts("PASS: native HLS byte-range parser (explicit, implicit, invalid)");
    return 0;
}
EOF

clang -std=c99 -O1 -Wall -Wextra -I"$SOURCE" \
    "$WORK/hls_parser_check.c" "$SOURCE/m3u8.c" \
    -o "$WORK/hls_parser_check"
"$WORK/hls_parser_check"
