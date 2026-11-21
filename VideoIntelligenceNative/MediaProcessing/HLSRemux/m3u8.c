#include "m3u8.h"
#include "hls2mp4.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void resolve_url(const char *base, const char *relative, char *out, size_t out_size)
{
    if (!relative || !out || out_size == 0) return;

    /* Absolute URL */
    if (strncmp(relative, "http://", 7) == 0 || strncmp(relative, "https://", 8) == 0) {
        snprintf(out, out_size, "%s", relative);
        return;
    }

    if (!base) {
        snprintf(out, out_size, "%s", relative);
        return;
    }

    /* Protocol-relative */
    if (relative[0] == '/' && relative[1] == '/') {
        const char *colon = strchr(base, ':');
        if (colon) {
            size_t plen = (size_t)(colon - base);
            snprintf(out, out_size, "%.*s:%s", (int)plen, base, relative);
        } else {
            snprintf(out, out_size, "https:%s", relative);
        }
        return;
    }

    /* Absolute path */
    if (relative[0] == '/') {
        /* Find scheme + host */
        const char *p = strstr(base, "://");
        if (p) {
            p += 3;
            const char *slash = strchr(p, '/');
            size_t host_len = slash ? (size_t)(slash - base) : strlen(base);
            snprintf(out, out_size, "%.*s%s", (int)host_len, base, relative);
        } else {
            snprintf(out, out_size, "%s", relative);
        }
        return;
    }

    /* Relative path — strip last component from base */
    const char *q = strrchr(base, '?');
    size_t base_len = q ? (size_t)(q - base) : strlen(base);
    const char *last_slash = NULL;
    for (size_t i = 0; i < base_len; i++) {
        if (base[i] == '/') last_slash = base + i;
    }
    if (last_slash) {
        size_t dir_len = (size_t)(last_slash - base) + 1;
        snprintf(out, out_size, "%.*s%s", (int)dir_len, base, relative);
    } else {
        snprintf(out, out_size, "%s", relative);
    }
}

static int hex_to_nibble(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return 10 + c - 'a';
    if (c >= 'A' && c <= 'F') return 10 + c - 'A';
    return -1;
}

static int parse_hex_iv(const char *hex, uint8_t iv[16])
{
    /* Skip 0x prefix */
    if (hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X'))
        hex += 2;
    size_t len = strlen(hex);
    if (len != 32) return -1;
    for (int i = 0; i < 16; i++) {
        int hi = hex_to_nibble(hex[i * 2]);
        int lo = hex_to_nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return -1;
        iv[i] = (uint8_t)((hi << 4) | lo);
    }
    return 0;
}

/* Extract a quoted value for a given attribute name from a tag line.
   e.g. from METHOD=AES-128,URI="http://...",IV=0x...
   For URI we expect quotes; for METHOD and IV no quotes. */
static int extract_attribute(const char *line, const char *attr, char *out, size_t out_size)
{
    char search[64];
    snprintf(search, sizeof(search), "%s=", attr);
    const char *p = strstr(line, search);
    if (!p) return -1;
    p += strlen(search);

    if (*p == '"') {
        p++;
        const char *end = strchr(p, '"');
        if (!end) return -1;
        size_t len = (size_t)(end - p);
        if (len >= out_size) len = out_size - 1;
        memcpy(out, p, len);
        out[len] = '\0';
    } else {
        const char *end = p;
        while (*end && *end != ',' && *end != '\n' && *end != '\r')
            end++;
        size_t len = (size_t)(end - p);
        if (len >= out_size) len = out_size - 1;
        memcpy(out, p, len);
        out[len] = '\0';
    }
    return 0;
}

/* Extract BANDWIDTH= value as integer */
static int extract_bandwidth(const char *line)
{
    char bw_str[32];
    if (extract_attribute(line, "BANDWIDTH", bw_str, sizeof(bw_str)) != 0)
        return 0;
    return atoi(bw_str);
}

int m3u8_parse(const char *data, size_t size, const char *base_url, M3U8Playlist *out)
{
    if (!data || !out)
        return HLS2MP4_ERR_PARSE;

    memset(out, 0, sizeof(*out));

    /* Check for #EXTM3U */
    if (size < 7 || strncmp(data, "#EXTM3U", 7) != 0)
        return HLS2MP4_ERR_PARSE;

    int best_bandwidth = 0;

    /* Current encryption state */
    char cur_key_url[2048];
    uint8_t cur_iv[16];
    int cur_has_iv = 0;
    cur_key_url[0] = '\0';

    /* Work with a null-terminated copy */
    char *buf = (char *)malloc(size + 1);
    if (!buf)
        return HLS2MP4_ERR_IO;
    memcpy(buf, data, size);
    buf[size] = '\0';

    /* Check for master playlist */
    if (strstr(buf, "#EXT-X-STREAM-INF")) {
        char best_variant_url[2048];
        best_variant_url[0] = '\0';

        /* Parse line by line */
        char *line = buf;
        int found_stream_inf = 0;
        int cur_bw = 0;
        while (line && *line) {
            char *eol = strchr(line, '\n');
            size_t line_len = eol ? (size_t)(eol - line) : strlen(line);
            /* Trim \r */
            if (line_len > 0 && line[line_len - 1] == '\r') line_len--;

            if (found_stream_inf && line_len > 0 && line[0] != '#') {
                /* This is the variant URL */
                if (cur_bw > best_bandwidth) {
                    best_bandwidth = cur_bw;
                    if (line_len >= sizeof(best_variant_url))
                        line_len = sizeof(best_variant_url) - 1;
                    memcpy(best_variant_url, line, line_len);
                    best_variant_url[line_len] = '\0';
                }
                found_stream_inf = 0;
            } else if (line_len >= 18 && strncmp(line, "#EXT-X-STREAM-INF:", 18) == 0) {
                /* Temporarily null-terminate for attribute parsing */
                char saved = line[line_len];
                line[line_len] = '\0';
                cur_bw = extract_bandwidth(line);
                line[line_len] = saved;
                found_stream_inf = 1;
            } else {
                found_stream_inf = 0;
            }

            line = eol ? eol + 1 : NULL;
        }

        if (best_variant_url[0]) {
            out->segments = (M3U8Segment *)calloc(1, sizeof(M3U8Segment));
            if (!out->segments) {
                free(buf);
                return HLS2MP4_ERR_IO;
            }
            resolve_url(base_url, best_variant_url, out->segments[0].url, sizeof(out->segments[0].url));
            out->count = -1; /* sentinel: master playlist */
            out->is_vod = 0;
            free(buf);
            return HLS2MP4_OK;
        }
        free(buf);
        return HLS2MP4_ERR_PARSE;
    }

    /* Media playlist parsing */
    int capacity = 64;
    out->segments = (M3U8Segment *)calloc((size_t)capacity, sizeof(M3U8Segment));
    if (!out->segments) {
        free(buf);
        return HLS2MP4_ERR_IO;
    }
    out->count = 0;
    out->is_vod = 0;

    float next_duration = 0.0f;
    int media_sequence = 0;
    int seg_index = 0;

    char *line = buf;
    while (line && *line) {
        char *eol = strchr(line, '\n');
        if (eol) *eol = '\0';
        size_t ll = strlen(line);
        if (ll > 0 && line[ll - 1] == '\r') line[ll - 1] = '\0';

        if (strncmp(line, "#EXT-X-MEDIA-SEQUENCE:", 22) == 0) {
            media_sequence = atoi(line + 22);
            seg_index = media_sequence;
        } else if (strncmp(line, "#EXT-X-KEY:", 11) == 0) {
            char method[32];
            method[0] = '\0';
            extract_attribute(line, "METHOD", method, sizeof(method));
            if (strcmp(method, "AES-128") == 0) {
                char uri[2048];
                uri[0] = '\0';
                extract_attribute(line, "URI", uri, sizeof(uri));
                resolve_url(base_url, uri, cur_key_url, sizeof(cur_key_url));

                char iv_str[64];
                iv_str[0] = '\0';
                if (extract_attribute(line, "IV", iv_str, sizeof(iv_str)) == 0 && iv_str[0]) {
                    if (parse_hex_iv(iv_str, cur_iv) == 0)
                        cur_has_iv = 1;
                    else
                        cur_has_iv = 0;
                } else {
                    cur_has_iv = 0;
                }
            } else if (strcmp(method, "NONE") == 0) {
                cur_key_url[0] = '\0';
                cur_has_iv = 0;
            }
        } else if (strncmp(line, "#EXTINF:", 8) == 0) {
            next_duration = (float)atof(line + 8);
        } else if (strncmp(line, "#EXT-X-ENDLIST", 14) == 0) {
            out->is_vod = 1;
        } else if (line[0] != '#' && line[0] != '\0') {
            /* This is a segment URL */
            if (out->count >= capacity) {
                capacity *= 2;
                M3U8Segment *tmp = (M3U8Segment *)realloc(out->segments,
                    (size_t)capacity * sizeof(M3U8Segment));
                if (!tmp) {
                    free(buf);
                    return HLS2MP4_ERR_IO;
                }
                out->segments = tmp;
            }
            M3U8Segment *seg = &out->segments[out->count];
            memset(seg, 0, sizeof(*seg));
            resolve_url(base_url, line, seg->url, sizeof(seg->url));
            seg->duration = next_duration;
            next_duration = 0.0f;

            if (cur_key_url[0]) {
                snprintf(seg->key_url, sizeof(seg->key_url), "%s", cur_key_url);
                if (cur_has_iv) {
                    memcpy(seg->iv, cur_iv, 16);
                    seg->has_iv = 1;
                } else {
                    /* Use segment sequence number as IV */
                    memset(seg->iv, 0, 16);
                    seg->iv[12] = (uint8_t)((seg_index >> 24) & 0xFF);
                    seg->iv[13] = (uint8_t)((seg_index >> 16) & 0xFF);
                    seg->iv[14] = (uint8_t)((seg_index >> 8) & 0xFF);
                    seg->iv[15] = (uint8_t)(seg_index & 0xFF);
                    seg->has_iv = 0;
                }
            }

            out->count++;
            seg_index++;
        }

        if (eol)
            line = eol + 1;
        else
            break;
    }

    free(buf);
    return HLS2MP4_OK;
}

void m3u8_free(M3U8Playlist *pl)
{
    if (!pl) return;
    free(pl->segments);
    pl->segments = NULL;
    pl->count = 0;
}
