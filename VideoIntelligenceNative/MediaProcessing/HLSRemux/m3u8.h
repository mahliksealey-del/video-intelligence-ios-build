#ifndef M3U8_H
#define M3U8_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    char     url[2048];
    float    duration;
    char     key_url[2048];   /* empty if not encrypted */
    uint8_t  iv[16];
    int      has_iv;          /* 1 if IV was explicit, 0 = use segment sequence number */
    int64_t  range_start;     /* start of HTTP byte range, 0 for full response */
    int64_t  range_length;    /* zero for full response, otherwise exact length */
} M3U8Segment;

typedef struct {
    M3U8Segment *segments;
    int          count;
    int          is_vod;      /* 1 if #EXT-X-ENDLIST present */
} M3U8Playlist;

int  m3u8_parse(const char *data, size_t size, const char *base_url, M3U8Playlist *out);
void m3u8_free(M3U8Playlist *pl);

#endif /* M3U8_H */
