#include "hls2mp4.h"
#include "http.h"
#include "m3u8.h"
#include "ts_demux.h"
#include "aes.h"
#include "muxer.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEFAULT_TIMEOUT_MS  10000
#define DEFAULT_MAX_RETRIES 3

/* Key cache entry */
typedef struct KeyCache {
    char     url[2048];
    uint8_t  key[16];
    struct KeyCache *next;
} KeyCache;

/* State passed through TS demux callback */
typedef struct {
    Muxer    *muxer;
    int       video_params_set;
    int       audio_params_set;
    int       error;

    /* PTS normalization: all timestamps are offset by base_pts so the
       output MP4 starts near time 0 while preserving the A/V offset. */
    int64_t   base_pts;       /* minimum PTS seen across all streams */
    int       base_pts_set;   /* 1 once base_pts is established */
} MuxState;

static void log_msg(const hls2mp4_options *opts, const char *fmt, ...)
{
    if (!opts->on_log) return;
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    opts->on_log(buf, opts->userdata);
}

/* Find SPS and PPS NAL units in H.264 Annex B data */
static int find_sps_pps(const uint8_t *data, size_t size,
                        const uint8_t **sps, size_t *sps_size,
                        const uint8_t **pps, size_t *pps_size)
{
    *sps = NULL; *sps_size = 0;
    *pps = NULL; *pps_size = 0;

    const uint8_t *p = data;
    const uint8_t *end = data + size;

    while (p + 4 <= end) {
        /* Find start code */
        if (p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) {
            const uint8_t *nal = p + 4;
            if (nal >= end) break;

            uint8_t nal_type = nal[0] & 0x1F;

            /* Find end of this NAL (next start code or end of data) */
            const uint8_t *nal_end = nal + 1;
            while (nal_end + 4 <= end) {
                if (nal_end[0] == 0 && nal_end[1] == 0 &&
                    nal_end[2] == 0 && nal_end[3] == 1)
                    break;
                if (nal_end[0] == 0 && nal_end[1] == 0 && nal_end[2] == 1)
                    break;
                nal_end++;
            }
            if (nal_end + 4 > end) nal_end = end;

            /* Trim trailing zeros */
            while (nal_end > nal && nal_end[-1] == 0)
                nal_end--;

            if (nal_type == 7 && !*sps) { /* SPS */
                *sps = nal;
                *sps_size = (size_t)(nal_end - nal);
            } else if (nal_type == 8 && !*pps) { /* PPS */
                *pps = nal;
                *pps_size = (size_t)(nal_end - nal);
            }

            if (*sps && *pps) return 0;
            p = nal_end;
        } else if (p[0] == 0 && p[1] == 0 && p[2] == 1) {
            const uint8_t *nal = p + 3;
            if (nal >= end) break;

            uint8_t nal_type = nal[0] & 0x1F;

            const uint8_t *nal_end = nal + 1;
            while (nal_end + 3 <= end) {
                if (nal_end[0] == 0 && nal_end[1] == 0 &&
                    (nal_end[2] == 1 || (nal_end[2] == 0 && nal_end + 3 < end && nal_end[3] == 1)))
                    break;
                nal_end++;
            }
            if (nal_end + 3 > end) nal_end = end;

            while (nal_end > nal && nal_end[-1] == 0)
                nal_end--;

            if (nal_type == 7 && !*sps) {
                *sps = nal;
                *sps_size = (size_t)(nal_end - nal);
            } else if (nal_type == 8 && !*pps) {
                *pps = nal;
                *pps_size = (size_t)(nal_end - nal);
            }

            if (*sps && *pps) return 0;
            p = nal_end;
        } else {
            p++;
        }
    }
    return (*sps && *pps) ? 0 : -1;
}

/* Bit reader for exp-golomb coded SPS fields */
typedef struct {
    const uint8_t *data;
    size_t         size;    /* in bytes */
    size_t         bit_pos;
} BitReader;

static void br_init(BitReader *br, const uint8_t *data, size_t size)
{
    br->data = data;
    br->size = size;
    br->bit_pos = 0;
}

static int br_read_bit(BitReader *br)
{
    if (br->bit_pos / 8 >= br->size) return 0;
    int bit = (br->data[br->bit_pos / 8] >> (7 - (br->bit_pos % 8))) & 1;
    br->bit_pos++;
    return bit;
}

static uint32_t br_read_bits(BitReader *br, int n)
{
    uint32_t val = 0;
    for (int i = 0; i < n; i++)
        val = (val << 1) | (uint32_t)br_read_bit(br);
    return val;
}

/* Unsigned exp-golomb */
static uint32_t br_read_ue(BitReader *br)
{
    int leading_zeros = 0;
    while (br_read_bit(br) == 0 && leading_zeros < 31)
        leading_zeros++;
    if (leading_zeros == 0) return 0;
    return (1u << leading_zeros) - 1 + br_read_bits(br, leading_zeros);
}

/* Signed exp-golomb */
static int32_t br_read_se(BitReader *br)
{
    uint32_t val = br_read_ue(br);
    if (val & 1)
        return (int32_t)((val + 1) / 2);
    else
        return -(int32_t)(val / 2);
}

/* Remove emulation prevention bytes (0x00 0x00 0x03 -> 0x00 0x00) */
static size_t sps_remove_emulation(uint8_t *dst, const uint8_t *src, size_t size)
{
    size_t j = 0;
    for (size_t i = 0; i < size; i++) {
        if (i + 2 < size && src[i] == 0 && src[i + 1] == 0 && src[i + 2] == 3) {
            dst[j++] = 0;
            dst[j++] = 0;
            i += 2; /* skip the 0x03 */
        } else {
            dst[j++] = src[i];
        }
    }
    return j;
}

/* Parse H.264 SPS NAL to extract width and height */
static void parse_sps_dimensions(const uint8_t *sps, size_t sps_size,
                                 int *width, int *height)
{
    *width = 1920;
    *height = 1080;

    if (sps_size < 4) return;

    /* Remove emulation prevention bytes */
    uint8_t *rbsp = (uint8_t *)malloc(sps_size);
    if (!rbsp) return;
    size_t rbsp_size = sps_remove_emulation(rbsp, sps, sps_size);

    BitReader br;
    /* SPS NAL: forbidden_zero_bit(1) + nal_ref_idc(2) + nal_unit_type(5) = 1 byte
       Then: profile_idc(8) + constraint_flags(8) + level_idc(8) = 3 bytes
       Start reading after byte 0 (NAL header) */
    br_init(&br, rbsp + 1, rbsp_size - 1);

    uint32_t profile_idc = br_read_bits(&br, 8);
    br_read_bits(&br, 8); /* constraint_set flags + reserved */
    br_read_bits(&br, 8); /* level_idc */
    br_read_ue(&br);      /* seq_parameter_set_id */

    /* High profile and above have additional fields */
    if (profile_idc == 100 || profile_idc == 110 || profile_idc == 122 ||
        profile_idc == 244 || profile_idc == 44  || profile_idc == 83  ||
        profile_idc == 86  || profile_idc == 118 || profile_idc == 128 ||
        profile_idc == 138 || profile_idc == 139 || profile_idc == 134 ||
        profile_idc == 135) {
        uint32_t chroma_format_idc = br_read_ue(&br);
        if (chroma_format_idc == 3)
            br_read_bits(&br, 1); /* separate_colour_plane_flag */
        br_read_ue(&br); /* bit_depth_luma_minus8 */
        br_read_ue(&br); /* bit_depth_chroma_minus8 */
        br_read_bits(&br, 1); /* qpprime_y_zero_transform_bypass_flag */
        uint32_t seq_scaling_matrix_present = br_read_bits(&br, 1);
        if (seq_scaling_matrix_present) {
            int limit = (chroma_format_idc != 3) ? 8 : 12;
            for (int i = 0; i < limit; i++) {
                uint32_t present = br_read_bits(&br, 1);
                if (present) {
                    int size_of_list = (i < 6) ? 16 : 64;
                    int last_scale = 8, next_scale = 8;
                    for (int j = 0; j < size_of_list; j++) {
                        if (next_scale != 0) {
                            int32_t delta = br_read_se(&br);
                            next_scale = (last_scale + delta + 256) % 256;
                        }
                        last_scale = (next_scale == 0) ? last_scale : next_scale;
                    }
                }
            }
        }
    }

    br_read_ue(&br); /* log2_max_frame_num_minus4 */
    uint32_t pic_order_cnt_type = br_read_ue(&br);
    if (pic_order_cnt_type == 0) {
        br_read_ue(&br); /* log2_max_pic_order_cnt_lsb_minus4 */
    } else if (pic_order_cnt_type == 1) {
        br_read_bits(&br, 1); /* delta_pic_order_always_zero_flag */
        br_read_se(&br);      /* offset_for_non_ref_pic */
        br_read_se(&br);      /* offset_for_top_to_bottom_field */
        uint32_t num_ref = br_read_ue(&br);
        for (uint32_t i = 0; i < num_ref; i++)
            br_read_se(&br);
    }

    br_read_ue(&br); /* max_num_ref_frames */
    br_read_bits(&br, 1); /* gaps_in_frame_num_value_allowed_flag */

    uint32_t pic_width_in_mbs = br_read_ue(&br) + 1;
    uint32_t pic_height_in_map_units = br_read_ue(&br) + 1;
    uint32_t frame_mbs_only_flag = br_read_bits(&br, 1);

    if (!frame_mbs_only_flag)
        br_read_bits(&br, 1); /* mb_adaptive_frame_field_flag */

    br_read_bits(&br, 1); /* direct_8x8_inference_flag */

    uint32_t frame_cropping_flag = br_read_bits(&br, 1);
    uint32_t crop_left = 0, crop_right = 0, crop_top = 0, crop_bottom = 0;
    if (frame_cropping_flag) {
        crop_left   = br_read_ue(&br);
        crop_right  = br_read_ue(&br);
        crop_top    = br_read_ue(&br);
        crop_bottom = br_read_ue(&br);
    }

    int w = (int)(pic_width_in_mbs * 16);
    int h = (int)(pic_height_in_map_units * 16 * (frame_mbs_only_flag ? 1 : 2));

    /* Apply cropping (SubWidthC and SubHeightC are 2 for 4:2:0) */
    int crop_unit_x = 2; /* for 4:2:0 */
    int crop_unit_y = 2 * (frame_mbs_only_flag ? 1 : 2);
    w -= (int)(crop_left + crop_right) * crop_unit_x;
    h -= (int)(crop_top + crop_bottom) * crop_unit_y;

    if (w > 0 && h > 0) {
        *width = w;
        *height = h;
    }

    free(rbsp);
}

/* Parse ADTS header for audio params */
static int parse_adts_params(const uint8_t *data, size_t size,
                             int *sample_rate, int *channels, int *profile)
{
    if (size < 7) return -1;
    if (data[0] != 0xFF || (data[1] & 0xF0) != 0xF0) return -1;

    int sr_index = (data[2] >> 2) & 0x0F;
    *channels = ((data[2] & 0x01) << 2) | ((data[3] >> 6) & 0x03);
    *profile = ((data[2] >> 6) & 0x03) + 1; /* ADTS profile is 0-based, AAC is 1-based */

    static const int sr_table[] = {
        96000, 88200, 64000, 48000, 44100, 32000,
        24000, 22050, 16000, 12000, 11025, 8000, 7350
    };
    if (sr_index < 13)
        *sample_rate = sr_table[sr_index];
    else
        *sample_rate = 44100;

    return 0;
}

static void ts_frame_callback(const TsFrame *frame, void *userdata)
{
    MuxState *ms = (MuxState *)userdata;
    if (ms->error) return;

    /* Establish base PTS from the very first timestamp we see (audio or video).
       All subsequent timestamps are normalized relative to this so the MP4
       starts near time 0 while preserving the A/V offset. */
    int64_t raw_pts = frame->pts;
    int64_t raw_dts = frame->dts;
    if (!ms->base_pts_set && raw_pts >= 0) {
        /* Use the earliest DTS if available, otherwise PTS */
        ms->base_pts = (raw_dts >= 0 && raw_dts < raw_pts) ? raw_dts : raw_pts;
        ms->base_pts_set = 1;
    }

    /* Update base if we see an earlier timestamp (audio often arrives
       before video in the demux callback order) */
    if (ms->base_pts_set) {
        int64_t earliest = (raw_dts >= 0) ? raw_dts : raw_pts;
        if (earliest >= 0 && earliest < ms->base_pts)
            ms->base_pts = earliest;
    }

    if (frame->type == STREAM_VIDEO) {
        if (!ms->video_params_set) {
            const uint8_t *sps, *pps;
            size_t sps_size, pps_size;
            if (find_sps_pps(frame->data, frame->size,
                             &sps, &sps_size, &pps, &pps_size) == 0) {
                int w, h;
                parse_sps_dimensions(sps, sps_size, &w, &h);
                if (muxer_set_video_params(ms->muxer, sps, sps_size,
                                           pps, pps_size, w, h) == HLS2MP4_OK) {
                    ms->video_params_set = 1;
                }
            }
        }
        if (ms->video_params_set) {
            /* Check if keyframe (IDR = NAL type 5) */
            int is_key = 0;
            const uint8_t *p = frame->data;
            const uint8_t *end = frame->data + frame->size;
            while (p + 4 <= end) {
                if (p[0] == 0 && p[1] == 0 && p[2] == 0 && p[3] == 1) {
                    if (p + 4 < end && (p[4] & 0x1F) == 5) is_key = 1;
                    break;
                }
                if (p[0] == 0 && p[1] == 0 && p[2] == 1) {
                    if (p + 3 < end && (p[3] & 0x1F) == 5) is_key = 1;
                    break;
                }
                p++;
            }

            int64_t dts_90k = (raw_dts >= 0) ? raw_dts : (raw_pts >= 0) ? raw_pts : 0;
            int64_t pts_90k = (raw_pts >= 0) ? raw_pts : dts_90k;

            /* Normalize relative to base */
            if (ms->base_pts_set) {
                dts_90k -= ms->base_pts;
                pts_90k -= ms->base_pts;
                if (dts_90k < 0) dts_90k = 0;
                if (pts_90k < 0) pts_90k = 0;
            }

            int ret = muxer_write_video(ms->muxer, frame->data, frame->size,
                                        dts_90k, pts_90k, is_key);
            if (ret != HLS2MP4_OK) ms->error = ret;
        }
    } else if (frame->type == STREAM_AUDIO) {
        if (!ms->audio_params_set) {
            int sr, ch, prof;
            if (parse_adts_params(frame->data, frame->size, &sr, &ch, &prof) == 0) {
                if (muxer_set_audio_params(ms->muxer, sr, ch, prof) == HLS2MP4_OK) {
                    ms->audio_params_set = 1;
                }
            }
        }
        if (ms->audio_params_set) {
            int64_t dts_90k = (raw_pts >= 0) ? raw_pts : 0;

            if (ms->base_pts_set) {
                dts_90k -= ms->base_pts;
                if (dts_90k < 0) dts_90k = 0;
            }

            int ret = muxer_write_audio(ms->muxer, frame->data, frame->size, dts_90k);
            if (ret != HLS2MP4_OK) ms->error = ret;
        }
    }
}

static KeyCache *key_cache_find(KeyCache *cache, const char *url)
{
    while (cache) {
        if (strcmp(cache->url, url) == 0)
            return cache;
        cache = cache->next;
    }
    return NULL;
}

static void key_cache_free(KeyCache *cache)
{
    while (cache) {
        KeyCache *next = cache->next;
        free(cache);
        cache = next;
    }
}

/* Number of segments to download ahead of the current one being processed */
#define PREFETCH_AHEAD 4

int hls2mp4_convert(const hls2mp4_options *opts)
{
    if (!opts || !opts->input_url || !opts->output_path)
        return HLS2MP4_ERR_IO;
    if (hls_remux_cancel_token_is_requested(opts->cancel_token))
        return HLS2MP4_ERR_CANCELED;

    int timeout = opts->timeout_ms > 0 ? opts->timeout_ms : DEFAULT_TIMEOUT_MS;
    int max_retries = opts->max_retries > 0 ? opts->max_retries : DEFAULT_MAX_RETRIES;

    int ret;

    /* Create a reusable HTTP session for playlists and keys */
    HttpSession *session = http_session_new(timeout);
    if (!session)
        return HLS2MP4_ERR_NETWORK;

    /* Step 1: Fetch and parse the M3U8 playlist */
    log_msg(opts, "Fetching playlist: %s", opts->input_url);

    uint8_t *m3u8_data = NULL;
    size_t m3u8_size = 0;
    ret = http_session_get(session, opts->input_url, &m3u8_data, &m3u8_size);
    if (ret != HLS2MP4_OK) {
        http_session_free(session);
        return ret;
    }

    M3U8Playlist playlist;
    ret = m3u8_parse((const char *)m3u8_data, m3u8_size, opts->input_url, &playlist);
    free(m3u8_data);
    if (ret != HLS2MP4_OK) {
        http_session_free(session);
        return ret;
    }

    /* If master playlist, follow the variant URL */
    if (playlist.count == -1) {
        log_msg(opts, "Master playlist detected, following variant: %s", playlist.segments[0].url);
        char variant_url[2048];
        snprintf(variant_url, sizeof(variant_url), "%s", playlist.segments[0].url);
        m3u8_free(&playlist);

        ret = http_session_get(session, variant_url, &m3u8_data, &m3u8_size);
        if (ret != HLS2MP4_OK) {
            http_session_free(session);
            return ret;
        }

        ret = m3u8_parse((const char *)m3u8_data, m3u8_size, variant_url, &playlist);
        free(m3u8_data);
        if (ret != HLS2MP4_OK) {
            http_session_free(session);
            return ret;
        }

        if (playlist.count <= 0) {
            m3u8_free(&playlist);
            http_session_free(session);
            return HLS2MP4_ERR_PARSE;
        }
    }

    log_msg(opts, "Playlist has %d segments, VOD=%d", playlist.count, playlist.is_vod);

    /* Step 2: Open muxer */
    Muxer *muxer = muxer_open(opts->output_path);
    if (!muxer) {
        m3u8_free(&playlist);
        http_session_free(session);
        return HLS2MP4_ERR_MUXER;
    }

    MuxState ms;
    memset(&ms, 0, sizeof(ms));
    ms.muxer = muxer;

    KeyCache *key_cache = NULL;

    /* Step 3: Process segments with prefetching.
       We download segments in batches using curl_multi for parallelism.
       While processing segment i, segments i+1..i+PREFETCH_AHEAD are
       already downloading in the background. */
    int batch_start = 0;
    while (batch_start < playlist.count) {
        int batch_end = batch_start + PREFETCH_AHEAD + 1;
        if (batch_end > playlist.count) batch_end = playlist.count;
        int batch_size = batch_end - batch_start;

        /* Create a prefetch batch for this window */
        HttpPrefetch *pf = http_prefetch_new(batch_size, timeout);
        if (!pf) {
            key_cache_free(key_cache);
            muxer_close(muxer);
            muxer_free(muxer);
            m3u8_free(&playlist);
            http_session_free(session);
            return HLS2MP4_ERR_IO;
        }

        /* Enqueue all segments in this batch for parallel download */
        for (int i = batch_start; i < batch_end; i++) {
            http_prefetch_enqueue(pf, playlist.segments[i].url, i);
        }

        /* Process segments in order as their downloads complete */
        for (int i = batch_start; i < batch_end; i++) {
            if (hls_remux_cancel_token_is_requested(opts->cancel_token)) {
                http_prefetch_free(pf);
                key_cache_free(key_cache);
                muxer_close(muxer);
                muxer_free(muxer);
                m3u8_free(&playlist);
                http_session_free(session);
                return HLS2MP4_ERR_CANCELED;
            }
            M3U8Segment *seg = &playlist.segments[i];
            log_msg(opts, "Processing segment %d/%d", i + 1, playlist.count);

            uint8_t *ts_data = NULL;
            size_t ts_size = 0;
            int fetched = 0;

            /* Try to get from prefetch first */
            ret = http_prefetch_get(pf, i, &ts_data, &ts_size);
            if (ret == HLS2MP4_OK) {
                fetched = 1;
            } else {
                /* Prefetch failed — retry with session handle */
                for (int attempt = 0; attempt < max_retries; attempt++) {
                    ret = http_session_get(session, seg->url, &ts_data, &ts_size);
                    if (ret == HLS2MP4_OK) {
                        fetched = 1;
                        break;
                    }
                    log_msg(opts, "Retry %d/%d for segment %d",
                            attempt + 1, max_retries, i + 1);
                }
            }

            if (!fetched) {
                http_prefetch_free(pf);
                key_cache_free(key_cache);
                muxer_close(muxer);
                muxer_free(muxer);
                m3u8_free(&playlist);
                http_session_free(session);
                return HLS2MP4_ERR_NETWORK;
            }

            /* Decrypt if needed */
            if (seg->key_url[0]) {
                KeyCache *kc = key_cache_find(key_cache, seg->key_url);
                if (!kc) {
                    uint8_t *key_data = NULL;
                    size_t key_size = 0;
                    ret = http_session_get(session, seg->key_url,
                                           &key_data, &key_size);
                    if (ret != HLS2MP4_OK || key_size != 16) {
                        free(key_data);
                        free(ts_data);
                        http_prefetch_free(pf);
                        key_cache_free(key_cache);
                        muxer_close(muxer);
                        muxer_free(muxer);
                        m3u8_free(&playlist);
                        http_session_free(session);
                        return HLS2MP4_ERR_DECRYPT;
                    }
                    kc = (KeyCache *)calloc(1, sizeof(KeyCache));
                    if (!kc) {
                        free(key_data);
                        free(ts_data);
                        http_prefetch_free(pf);
                        key_cache_free(key_cache);
                        muxer_close(muxer);
                        muxer_free(muxer);
                        m3u8_free(&playlist);
                        http_session_free(session);
                        return HLS2MP4_ERR_IO;
                    }
                    snprintf(kc->url, sizeof(kc->url), "%s", seg->key_url);
                    memcpy(kc->key, key_data, 16);
                    kc->next = key_cache;
                    key_cache = kc;
                    free(key_data);
                }

                size_t decrypt_size = ts_size - (ts_size % 16);
                if (decrypt_size > 0) {
                    ret = aes128_cbc_decrypt(ts_data, decrypt_size,
                                             kc->key, seg->iv);
                    if (ret != HLS2MP4_OK) {
                        free(ts_data);
                        http_prefetch_free(pf);
                        key_cache_free(key_cache);
                        muxer_close(muxer);
                        muxer_free(muxer);
                        m3u8_free(&playlist);
                        http_session_free(session);
                        return ret;
                    }
                    uint8_t pad = ts_data[decrypt_size - 1];
                    if (pad > 0 && pad <= 16)
                        ts_size = decrypt_size - pad;
                }
            }

            /* Demux TS data */
            ret = ts_demux(ts_data, ts_size, ts_frame_callback, &ms);
            free(ts_data);

            if (ret != HLS2MP4_OK || ms.error) {
                http_prefetch_free(pf);
                key_cache_free(key_cache);
                muxer_close(muxer);
                muxer_free(muxer);
                m3u8_free(&playlist);
                http_session_free(session);
                return (ms.error) ? ms.error : ret;
            }

            if (opts->on_progress)
                opts->on_progress(i + 1, playlist.count, opts->userdata);
        }

        http_prefetch_free(pf);
        batch_start = batch_end;
    }

    /* Step 4: Finalize */
    key_cache_free(key_cache);
    http_session_free(session);
    ret = muxer_close(muxer);
    muxer_free(muxer);
    m3u8_free(&playlist);

    if (ret != HLS2MP4_OK)
        return ret;

    log_msg(opts, "Conversion complete: %s", opts->output_path);
    return HLS2MP4_OK;
}

const char *hls2mp4_error_string(int code)
{
    switch (code) {
        case HLS2MP4_OK:           return "Success";
        case HLS2MP4_ERR_NETWORK:  return "Network error";
        case HLS2MP4_ERR_PARSE:    return "Playlist parse error";
        case HLS2MP4_ERR_DEMUX:    return "TS demux error";
        case HLS2MP4_ERR_DECRYPT:  return "Decryption error";
        case HLS2MP4_ERR_MUXER:    return "Muxer error";
        case HLS2MP4_ERR_IO:       return "I/O error";
        case HLS2MP4_ERR_CANCELED: return "Canceled by user";
        default:                   return "Unknown error";
    }
}
