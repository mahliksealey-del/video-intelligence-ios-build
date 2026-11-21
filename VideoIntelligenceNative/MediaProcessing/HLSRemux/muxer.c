#include "muxer.h"
#include "hls2mp4.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MINIMP4_IMPLEMENTATION
#include "minimp4.h"

/* Track composition offsets for ctts box injection */
typedef struct {
    int32_t *offsets;     /* PTS - DTS for each video sample (in 90kHz) */
    int      count;
    int      capacity;
    int      all_zero;    /* optimization: skip ctts if no B-frames */
} CttsData;

struct Muxer {
    FILE         *fp;
    char         *path;
    MP4E_mux_t   *mux;
    mp4_h26x_writer_t h264_writer;
    int           video_track;
    int           audio_track;
    int           video_initialized;
    int           audio_initialized;
    int           width;
    int           height;
    int           sample_rate;
    int           channels;

    int           audio_primed;        /* 1 after first audio frame processed */
    int           audio_delay_samples; /* initial delay in audio samples */
    int           audio_first_written; /* 1 after first real audio sample */

    /* Deferred video write for DTS-based duration computation */
    uint8_t      *pending_video;
    size_t        pending_video_size;
    int64_t       pending_video_dts;
    int64_t       pending_video_pts;
    int           has_pending_video;

    /* Composition time offset tracking */
    CttsData      ctts;
    int64_t       first_dts;   /* DTS of first video frame, for normalization */
    int           first_dts_set;
};

static int mp4_write_callback(int64_t offset, const void *buffer, size_t size, void *token)
{
    FILE *fp = (FILE *)token;
    if (fseek(fp, (long)offset, SEEK_SET) != 0)
        return 1;
    if (fwrite(buffer, 1, size, fp) != size)
        return 1;
    return 0;
}

static void ctts_init(CttsData *c)
{
    memset(c, 0, sizeof(*c));
    c->all_zero = 1;
}

static int ctts_add(CttsData *c, int32_t offset)
{
    if (c->count >= c->capacity) {
        int new_cap = c->capacity == 0 ? 256 : c->capacity * 2;
        int32_t *tmp = (int32_t *)realloc(c->offsets, (size_t)new_cap * sizeof(int32_t));
        if (!tmp) return -1;
        c->offsets = tmp;
        c->capacity = new_cap;
    }
    c->offsets[c->count++] = offset;
    if (offset != 0) c->all_zero = 0;
    return 0;
}

static void ctts_free(CttsData *c)
{
    free(c->offsets);
    memset(c, 0, sizeof(*c));
}

Muxer *muxer_open(const char *path)
{
    if (!path) return NULL;

    Muxer *m = (Muxer *)calloc(1, sizeof(Muxer));
    if (!m) return NULL;

    m->path = (char *)malloc(strlen(path) + 1);
    if (!m->path) { free(m); return NULL; }
    strcpy(m->path, path);

    m->fp = fopen(path, "wb");
    if (!m->fp) {
        free(m->path);
        free(m);
        return NULL;
    }

    m->mux = MP4E_open(0, 0, m->fp, mp4_write_callback);
    if (!m->mux) {
        fclose(m->fp);
        free(m->path);
        free(m);
        return NULL;
    }

    m->video_track = -1;
    m->audio_track = -1;
    ctts_init(&m->ctts);
    return m;
}

int muxer_set_video_params(Muxer *m, const uint8_t *sps, size_t sps_size,
                                     const uint8_t *pps, size_t pps_size,
                                     int width, int height)
{
    if (!m || !sps || !pps || sps_size == 0 || pps_size == 0)
        return HLS2MP4_ERR_MUXER;

    if (m->video_initialized)
        return HLS2MP4_OK;

    m->width = width;
    m->height = height;

    MP4E_set_text_comment(m->mux, "hls2mp4");

    if (mp4_h26x_write_init(&m->h264_writer, m->mux, width, height, 0) != MP4E_STATUS_OK)
        return HLS2MP4_ERR_MUXER;

    m->video_initialized = 1;
    return HLS2MP4_OK;
}

static int sr_to_freq_index(int sample_rate)
{
    switch (sample_rate) {
        case 96000: return 0;
        case 88200: return 1;
        case 64000: return 2;
        case 48000: return 3;
        case 44100: return 4;
        case 32000: return 5;
        case 24000: return 6;
        case 22050: return 7;
        case 16000: return 8;
        case 12000: return 9;
        case 11025: return 10;
        case 8000:  return 11;
        case 7350:  return 12;
        default:    return 4;
    }
}

int muxer_set_audio_params(Muxer *m, int sample_rate,
                           int channels, int aac_profile)
{
    if (!m)
        return HLS2MP4_ERR_MUXER;

    if (m->audio_initialized)
        return HLS2MP4_OK;

    m->sample_rate = sample_rate;
    m->channels = channels;

    MP4E_track_t tr;
    memset(&tr, 0, sizeof(tr));
    tr.track_media_kind = e_audio;
    tr.language[0] = 'u'; tr.language[1] = 'n';
    tr.language[2] = 'd'; tr.language[3] = '\0';
    tr.object_type_indication = MP4_OBJECT_TYPE_AUDIO_ISO_IEC_14496_3;
    tr.time_scale = sample_rate;
    tr.default_duration = 1024;
    tr.u.a.channelcount = channels;

    int freq_index = sr_to_freq_index(sample_rate);
    int obj_type = (aac_profile > 0) ? aac_profile : 2;
    uint8_t dsi[2];
    dsi[0] = (uint8_t)((obj_type << 3) | (freq_index >> 1));
    dsi[1] = (uint8_t)(((freq_index & 1) << 7) | (channels << 3));

    m->audio_track = MP4E_add_track(m->mux, &tr);
    if (m->audio_track < 0)
        return HLS2MP4_ERR_MUXER;

    if (MP4E_set_dsi(m->mux, m->audio_track, dsi, sizeof(dsi)) != MP4E_STATUS_OK)
        return HLS2MP4_ERR_MUXER;

    m->audio_initialized = 1;
    return HLS2MP4_OK;
}

/* --- NAL filtering --- */

static const uint8_t *find_start_code_muxer(const uint8_t *p, const uint8_t *end, int *sc_len)
{
    while (p + 3 <= end) {
        if (p[0] == 0 && p[1] == 0) {
            if (p[2] == 1) { *sc_len = 3; return p; }
            if (p[2] == 0 && p + 4 <= end && p[3] == 1) { *sc_len = 4; return p; }
        }
        p++;
    }
    return NULL;
}

static uint8_t *filter_nals(const uint8_t *data, size_t size, size_t *out_size)
{
    uint8_t *filtered = (uint8_t *)malloc(size);
    if (!filtered) { *out_size = 0; return NULL; }
    size_t filt_size = 0;

    const uint8_t *p = data;
    const uint8_t *end = data + size;

    while (p < end) {
        int sc_len = 0;
        const uint8_t *sc = find_start_code_muxer(p, end, &sc_len);
        if (!sc) break;

        const uint8_t *nal_body = sc + sc_len;
        if (nal_body >= end) break;

        uint8_t nal_type = nal_body[0] & 0x1F;

        int next_sc_len = 0;
        const uint8_t *next_sc = find_start_code_muxer(nal_body, end, &next_sc_len);
        const uint8_t *nal_end = next_sc ? next_sc : end;

        if (nal_type == 7 || nal_type == 8 || nal_type == 5 || nal_type == 1) {
            size_t chunk = (size_t)(nal_end - sc);
            memcpy(filtered + filt_size, sc, chunk);
            filt_size += chunk;
        }
        p = nal_end;
    }

    *out_size = filt_size;
    return filtered;
}

/* --- Deferred video write --- */

static int flush_pending_video(Muxer *m, unsigned duration_90k)
{
    if (!m->has_pending_video)
        return HLS2MP4_OK;

    /* Record composition offset: PTS - DTS (in 90kHz ticks) */
    int32_t cts_offset = (int32_t)(m->pending_video_pts - m->pending_video_dts);
    ctts_add(&m->ctts, cts_offset);

    int ret = mp4_h26x_write_nal(&m->h264_writer, m->pending_video,
                                  (int)m->pending_video_size, duration_90k);
    free(m->pending_video);
    m->pending_video = NULL;
    m->pending_video_size = 0;
    m->has_pending_video = 0;

    return (ret == MP4E_STATUS_OK) ? HLS2MP4_OK : HLS2MP4_ERR_MUXER;
}

int muxer_write_video(Muxer *m, const uint8_t *data,
                      size_t size, int64_t dts_90k, int64_t pts_90k,
                      int is_keyframe)
{
    if (!m || !data || size == 0)
        return HLS2MP4_ERR_MUXER;
    if (!m->video_initialized)
        return HLS2MP4_ERR_MUXER;

    (void)is_keyframe;

    /* Skip frames with non-increasing DTS (duplicates at segment boundaries) */
    if (m->has_pending_video && dts_90k >= 0 && dts_90k <= m->pending_video_dts) {
        return HLS2MP4_OK;
    }

    size_t filt_size = 0;
    uint8_t *filtered = filter_nals(data, size, &filt_size);
    if (!filtered)
        return HLS2MP4_ERR_IO;
    if (filt_size == 0) {
        free(filtered);
        return HLS2MP4_OK;
    }

    /* Flush previous frame with real duration */
    if (m->has_pending_video) {
        unsigned duration;
        if (dts_90k > m->pending_video_dts && dts_90k >= 0 && m->pending_video_dts >= 0) {
            duration = (unsigned)(dts_90k - m->pending_video_dts);
        } else {
            duration = 3000;
        }
        if (duration < 90) duration = 90;
        if (duration > 45000) duration = 45000;

        int ret = flush_pending_video(m, duration);
        if (ret != HLS2MP4_OK) {
            free(filtered);
            return ret;
        }
    }

    m->pending_video = filtered;
    m->pending_video_size = filt_size;
    m->pending_video_dts = dts_90k;
    m->pending_video_pts = pts_90k;
    m->has_pending_video = 1;

    return HLS2MP4_OK;
}

int muxer_write_audio(Muxer *m, const uint8_t *data,
                      size_t size, int64_t dts_90k)
{
    if (!m || !data || size == 0)
        return HLS2MP4_ERR_MUXER;
    if (!m->audio_initialized)
        return HLS2MP4_ERR_MUXER;

    /* On the first audio frame, if audio starts after video (dts_90k > 0),
       account for the initial delay by giving the first audio sample an
       extended duration. This shifts the audio timeline forward without
       needing synthetic silence frames. */
    if (!m->audio_primed) {
        m->audio_primed = 1;
        if (dts_90k > 0 && m->sample_rate > 0) {
            int64_t delay_samples = (dts_90k * m->sample_rate) / 90000;
            if (delay_samples > 0 && delay_samples < (int64_t)m->sample_rate * 10) {
                m->audio_delay_samples = (int)delay_samples;
            }
        }
    }

    const uint8_t *p = data;
    const uint8_t *end = data + size;

    while (p + 7 <= end) {
        if (p[0] == 0xFF && (p[1] & 0xF0) == 0xF0) {
            int no_crc = p[1] & 0x01;
            int header_size = no_crc ? 7 : 9;
            int frame_length = ((p[3] & 0x03) << 11) | (p[4] << 3) | ((p[5] >> 5) & 0x07);

            if (frame_length < header_size || p + frame_length > end)
                break;

            const uint8_t *aac_data = p + header_size;
            int aac_size = frame_length - header_size;

            if (aac_size > 0) {
                int duration = 1024;
                /* First audio sample gets extended duration to encode
                   the initial A/V delay */
                if (!m->audio_first_written && m->audio_delay_samples > 0) {
                    duration += m->audio_delay_samples;
                    m->audio_delay_samples = 0;
                }
                m->audio_first_written = 1;
                MP4E_put_sample(m->mux, m->audio_track,
                                aac_data, aac_size, duration, MP4E_SAMPLE_DEFAULT);
            }
            p += frame_length;
        } else {
            MP4E_put_sample(m->mux, m->audio_track,
                            p, (int)(end - p), 1024, MP4E_SAMPLE_DEFAULT);
            break;
        }
    }

    return HLS2MP4_OK;
}

/* --- ctts injection post-process --- */

static uint32_t rd32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

static void wr32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);
    p[3] = (uint8_t)(v);
}

/*
 * Inject a ctts box into the MP4 file after the stts box in the first video trak.
 * Strategy: read the file, find moov > trak > mdia > minf > stbl > stts,
 * insert ctts right after stts, and update all parent box sizes.
 */
static int inject_ctts(const char *path, const CttsData *ctts)
{
    if (!ctts || ctts->count == 0 || ctts->all_zero)
        return 0; /* no B-frames, nothing to do */

    FILE *fp = fopen(path, "rb");
    if (!fp) return -1;

    fseek(fp, 0, SEEK_END);
    long file_size = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    uint8_t *buf = (uint8_t *)malloc((size_t)file_size);
    if (!buf) { fclose(fp); return -1; }
    if ((long)fread(buf, 1, (size_t)file_size, fp) != file_size) {
        free(buf); fclose(fp); return -1;
    }
    fclose(fp);

    /* Build ctts box: run-length encode the offsets */
    /* First, count runs */
    int run_count = 0;
    {
        int i = 0;
        while (i < ctts->count) {
            int32_t val = ctts->offsets[i];
            while (i < ctts->count && ctts->offsets[i] == val) i++;
            run_count++;
        }
    }

    /* ctts box: full box header(12) + entry_count(4) + entries(8 each) */
    size_t ctts_size = 12 + 4 + (size_t)run_count * 8;
    uint8_t *ctts_box = (uint8_t *)malloc(ctts_size);
    if (!ctts_box) { free(buf); return -1; }

    /* Box header */
    wr32(ctts_box, (uint32_t)ctts_size);
    ctts_box[4] = 'c'; ctts_box[5] = 't'; ctts_box[6] = 't'; ctts_box[7] = 's';
    /* Version 0, flags 0 */
    wr32(ctts_box + 8, 0);
    /* Entry count */
    wr32(ctts_box + 12, (uint32_t)run_count);

    /* Entries */
    {
        int i = 0, e = 0;
        while (i < ctts->count) {
            int32_t val = ctts->offsets[i];
            uint32_t cnt = 0;
            while (i < ctts->count && ctts->offsets[i] == val) { i++; cnt++; }
            wr32(ctts_box + 16 + e * 8, cnt);
            wr32(ctts_box + 16 + e * 8 + 4, (uint32_t)val);
            e++;
        }
    }

    /* Find stts box position in the first video trak's stbl.
       We need to walk: moov > trak > mdia > minf > stbl > stts */
    long stts_end = -1;  /* byte offset right after the stts box */

    /* Track parent box offsets so we can update their sizes */
    long moov_off = -1, trak_off = -1, mdia_off = -1, minf_off = -1, stbl_off = -1;

    /* Simple recursive box scanner */
    long off = 0;
    /* Find moov */
    while (off + 8 <= file_size) {
        uint32_t sz = rd32(buf + off);
        if (sz < 8) break;
        if (buf[off+4]=='m' && buf[off+5]=='o' && buf[off+6]=='o' && buf[off+7]=='v') {
            moov_off = off;
            break;
        }
        off += sz;
    }
    if (moov_off < 0) { free(ctts_box); free(buf); return -1; }

    /* Find first trak inside moov */
    {
        uint32_t moov_sz = rd32(buf + moov_off);
        long end_moov = moov_off + moov_sz;
        off = moov_off + 8;
        while (off + 8 <= end_moov) {
            uint32_t sz = rd32(buf + off);
            if (sz < 8) break;
            if (buf[off+4]=='t' && buf[off+5]=='r' && buf[off+6]=='a' && buf[off+7]=='k') {
                trak_off = off;
                break;
            }
            off += sz;
        }
    }
    if (trak_off < 0) { free(ctts_box); free(buf); return -1; }

    /* Find mdia inside trak */
    {
        uint32_t trak_sz = rd32(buf + trak_off);
        long end_trak = trak_off + trak_sz;
        off = trak_off + 8;
        while (off + 8 <= end_trak) {
            uint32_t sz = rd32(buf + off);
            if (sz < 8) break;
            if (buf[off+4]=='m' && buf[off+5]=='d' && buf[off+6]=='i' && buf[off+7]=='a') {
                mdia_off = off;
                break;
            }
            off += sz;
        }
    }
    if (mdia_off < 0) { free(ctts_box); free(buf); return -1; }

    /* Find minf inside mdia */
    {
        uint32_t mdia_sz = rd32(buf + mdia_off);
        long end_mdia = mdia_off + mdia_sz;
        off = mdia_off + 8;
        while (off + 8 <= end_mdia) {
            uint32_t sz = rd32(buf + off);
            if (sz < 8) break;
            if (buf[off+4]=='m' && buf[off+5]=='i' && buf[off+6]=='n' && buf[off+7]=='f') {
                minf_off = off;
                break;
            }
            off += sz;
        }
    }
    if (minf_off < 0) { free(ctts_box); free(buf); return -1; }

    /* Find stbl inside minf */
    {
        uint32_t minf_sz = rd32(buf + minf_off);
        long end_minf = minf_off + minf_sz;
        off = minf_off + 8;
        while (off + 8 <= end_minf) {
            uint32_t sz = rd32(buf + off);
            if (sz < 8) break;
            if (buf[off+4]=='s' && buf[off+5]=='t' && buf[off+6]=='b' && buf[off+7]=='l') {
                stbl_off = off;
                break;
            }
            off += sz;
        }
    }
    if (stbl_off < 0) { free(ctts_box); free(buf); return -1; }

    /* Find stts inside stbl */
    {
        uint32_t stbl_sz = rd32(buf + stbl_off);
        long end_stbl = stbl_off + stbl_sz;
        off = stbl_off + 8;
        while (off + 8 <= end_stbl) {
            uint32_t sz = rd32(buf + off);
            if (sz < 8) break;
            if (buf[off+4]=='s' && buf[off+5]=='t' && buf[off+6]=='t' && buf[off+7]=='s') {
                stts_end = off + sz;
                break;
            }
            off += sz;
        }
    }
    if (stts_end < 0) { free(ctts_box); free(buf); return -1; }

    /* Build new file: [before stts_end] + [ctts_box] + [after stts_end] */
    size_t new_size = (size_t)file_size + ctts_size;
    uint8_t *new_buf = (uint8_t *)malloc(new_size);
    if (!new_buf) { free(ctts_box); free(buf); return -1; }

    memcpy(new_buf, buf, (size_t)stts_end);
    memcpy(new_buf + stts_end, ctts_box, ctts_size);
    memcpy(new_buf + stts_end + ctts_size, buf + stts_end, (size_t)(file_size - stts_end));

    /* Update parent box sizes (add ctts_size to each) */
    wr32(new_buf + moov_off, rd32(new_buf + moov_off) + (uint32_t)ctts_size);
    wr32(new_buf + trak_off, rd32(new_buf + trak_off) + (uint32_t)ctts_size);
    wr32(new_buf + mdia_off, rd32(new_buf + mdia_off) + (uint32_t)ctts_size);
    wr32(new_buf + minf_off, rd32(new_buf + minf_off) + (uint32_t)ctts_size);
    wr32(new_buf + stbl_off, rd32(new_buf + stbl_off) + (uint32_t)ctts_size);

    /* Also need to update stco (chunk offset table) if it comes after stts,
       since we shifted data. All chunk offsets pointing past stts_end need
       to be incremented by ctts_size. */
    /* Find stco inside stbl (in the new buffer, stbl position hasn't changed
       but its contents after stts_end have shifted) */
    {
        uint32_t stbl_sz = rd32(new_buf + stbl_off);
        long end_stbl = stbl_off + (long)stbl_sz;
        long s = stbl_off + 8;
        while (s + 8 <= end_stbl) {
            uint32_t sz = rd32(new_buf + s);
            if (sz < 8) break;
            if (new_buf[s+4]=='s' && new_buf[s+5]=='t' && new_buf[s+6]=='c' && new_buf[s+7]=='o') {
                /* stco: version(4) + entry_count(4) + offsets(4 each) */
                uint32_t entry_count = rd32(new_buf + s + 12);
                for (uint32_t i = 0; i < entry_count; i++) {
                    long pos = s + 16 + i * 4;
                    uint32_t chunk_off = rd32(new_buf + pos);
                    /* If this chunk offset points into data after where we inserted ctts,
                       shift it forward */
                    if ((long)chunk_off >= stts_end)
                        wr32(new_buf + pos, chunk_off + (uint32_t)ctts_size);
                }
            }
            if (new_buf[s+4]=='c' && new_buf[s+5]=='o' && new_buf[s+6]=='6' && new_buf[s+7]=='4') {
                /* co64: version(4) + entry_count(4) + offsets(8 each) */
                uint32_t entry_count = rd32(new_buf + s + 12);
                for (uint32_t i = 0; i < entry_count; i++) {
                    long pos = s + 16 + i * 8;
                    uint64_t chunk_off = ((uint64_t)rd32(new_buf + pos) << 32) | rd32(new_buf + pos + 4);
                    if ((int64_t)chunk_off >= stts_end) {
                        chunk_off += ctts_size;
                        wr32(new_buf + pos, (uint32_t)(chunk_off >> 32));
                        wr32(new_buf + pos + 4, (uint32_t)chunk_off);
                    }
                }
            }
            s += sz;
        }
    }

    /* Also fix stco in audio track if present (second trak) */
    {
        uint32_t moov_sz = rd32(new_buf + moov_off);
        long end_moov = moov_off + (long)moov_sz;
        long t = trak_off + rd32(new_buf + trak_off); /* skip first trak */
        while (t + 8 <= end_moov) {
            uint32_t sz = rd32(new_buf + t);
            if (sz < 8) break;
            if (new_buf[t+4]=='t' && new_buf[t+5]=='r' && new_buf[t+6]=='a' && new_buf[t+7]=='k') {
                /* Find stbl > stco inside this trak */
                long tt = t + 8;
                long tt_end = t + sz;
                while (tt + 8 <= tt_end) {
                    uint32_t ssz = rd32(new_buf + tt);
                    if (ssz < 8) break;
                    /* Recursively search for stco/co64 inside this trak */
                    if ((new_buf[tt+4]=='s' && new_buf[tt+5]=='t' && new_buf[tt+6]=='c' && new_buf[tt+7]=='o') ||
                        (new_buf[tt+4]=='c' && new_buf[tt+5]=='o' && new_buf[tt+6]=='6' && new_buf[tt+7]=='4')) {
                        int is_co64 = (new_buf[tt+4]=='c');
                        uint32_t entry_count = rd32(new_buf + tt + 12);
                        int entry_size = is_co64 ? 8 : 4;
                        for (uint32_t i = 0; i < entry_count; i++) {
                            long pos = tt + 16 + i * entry_size;
                            if (is_co64) {
                                uint64_t co = ((uint64_t)rd32(new_buf+pos) << 32) | rd32(new_buf+pos+4);
                                if ((int64_t)co >= stts_end) {
                                    co += ctts_size;
                                    wr32(new_buf+pos, (uint32_t)(co >> 32));
                                    wr32(new_buf+pos+4, (uint32_t)co);
                                }
                            } else {
                                uint32_t co = rd32(new_buf + pos);
                                if ((long)co >= stts_end)
                                    wr32(new_buf + pos, co + (uint32_t)ctts_size);
                            }
                        }
                    }
                    tt += ssz;
                }
            }
            t += sz;
        }
    }

    /* Write the new file */
    fp = fopen(path, "wb");
    if (!fp) { free(new_buf); free(ctts_box); free(buf); return -1; }
    fwrite(new_buf, 1, new_size, fp);
    fclose(fp);

    free(new_buf);
    free(ctts_box);
    free(buf);
    return 0;
}

int muxer_close(Muxer *m)
{
    if (!m) return HLS2MP4_ERR_MUXER;

    /* Flush last pending video frame */
    if (m->has_pending_video)
        flush_pending_video(m, 3000);

    if (m->video_initialized)
        mp4_h26x_write_close(&m->h264_writer);

    if (m->mux) {
        MP4E_close(m->mux);
        m->mux = NULL;
    }

    if (m->fp) {
        fclose(m->fp);
        m->fp = NULL;
    }

    /* Post-process: inject ctts box if B-frames were detected */
    if (!m->ctts.all_zero && m->ctts.count > 0 && m->path) {
        inject_ctts(m->path, &m->ctts);
    }

    return HLS2MP4_OK;
}

void muxer_free(Muxer *m)
{
    if (!m) return;
    free(m->pending_video);
    free(m->path);
    ctts_free(&m->ctts);
    if (m->mux) MP4E_close(m->mux);
    if (m->fp) fclose(m->fp);
    free(m);
}
