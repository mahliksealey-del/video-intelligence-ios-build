#include "ts_demux.h"
#include "hls2mp4.h"

#include <stdlib.h>
#include <string.h>

#define TS_PACKET_SIZE 188
#define TS_SYNC_BYTE   0x47
#define PID_PAT        0x0000
#define PID_NULL       0x1FFF

/* Stream types from PMT */
#define STREAM_TYPE_H264    0x1B
#define STREAM_TYPE_AAC     0x0F
#define STREAM_TYPE_MP3     0x03

/* Max PES reassembly buffer: 2 MB should handle any reasonable PES */
#define MAX_PES_SIZE (2 * 1024 * 1024)

typedef struct {
    uint16_t pmt_pid;
    uint16_t video_pid;
    uint16_t audio_pid;
    uint8_t  video_stream_type;
    uint8_t  audio_stream_type;

    uint8_t *video_pes;
    size_t   video_pes_size;
    size_t   video_pes_capacity;
    int      video_pes_started;

    uint8_t *audio_pes;
    size_t   audio_pes_size;
    size_t   audio_pes_capacity;
    int      audio_pes_started;

    ts_frame_cb callback;
    void       *userdata;
} DemuxState;

static int64_t parse_pts(const uint8_t *p)
{
    int64_t pts = 0;
    pts  = ((int64_t)(p[0] & 0x0E)) << 29;
    pts |= ((int64_t)(p[1]))        << 22;
    pts |= ((int64_t)(p[2] & 0xFE)) << 14;
    pts |= ((int64_t)(p[3]))        << 7;
    pts |= ((int64_t)(p[4] & 0xFE)) >> 1;
    return pts;
}

static void flush_pes(DemuxState *st, StreamType type)
{
    uint8_t *pes;
    size_t   pes_size;

    if (type == STREAM_VIDEO) {
        pes = st->video_pes;
        pes_size = st->video_pes_size;
    } else {
        pes = st->audio_pes;
        pes_size = st->audio_pes_size;
    }

    if (pes_size < 9) goto done;

    /* Parse PES header */
    if (pes[0] != 0x00 || pes[1] != 0x00 || pes[2] != 0x01)
        goto done;

    /* uint8_t stream_id = pes[3]; */
    /* uint16_t pes_length = (pes[4] << 8) | pes[5]; */
    uint8_t flags = pes[7];
    uint8_t header_data_len = pes[8];

    int64_t pts = -1;
    int64_t dts = -1;

    if (flags & 0x80) { /* PTS present */
        if (pes_size >= 14)
            pts = parse_pts(pes + 9);
    }
    if (flags & 0x40) { /* DTS present */
        if (pes_size >= 19)
            dts = parse_pts(pes + 14);
    }

    size_t payload_offset = 9 + header_data_len;
    if (payload_offset >= pes_size)
        goto done;

    TsFrame frame;
    frame.type = type;
    frame.data = pes + payload_offset;
    frame.size = pes_size - payload_offset;
    frame.pts = pts;
    frame.dts = dts;

    if (st->callback)
        st->callback(&frame, st->userdata);

done:
    if (type == STREAM_VIDEO) {
        st->video_pes_size = 0;
    } else {
        st->audio_pes_size = 0;
    }
}

static int append_pes(uint8_t **pes, size_t *pes_size, size_t *pes_capacity,
                      const uint8_t *data, size_t len)
{
    if (*pes_size + len > *pes_capacity) {
        size_t new_cap = (*pes_capacity == 0) ? 8192 : *pes_capacity;
        while (new_cap < *pes_size + len) {
            if (new_cap > MAX_PES_SIZE) return -1;
            new_cap *= 2;
        }
        uint8_t *tmp = (uint8_t *)realloc(*pes, new_cap);
        if (!tmp) return -1;
        *pes = tmp;
        *pes_capacity = new_cap;
    }
    memcpy(*pes + *pes_size, data, len);
    *pes_size += len;
    return 0;
}

static void parse_pat(DemuxState *st, const uint8_t *payload, size_t len)
{
    if (len < 8) return;

    /* Skip table_id(1), section syntax + length(2), transport_stream_id(2),
       version/cni(1), section_number(1), last_section_number(1) */
    size_t offset = 8;
    /* Each entry is 4 bytes: program_number(2) + PID(2) */
    while (offset + 4 <= len) {
        uint16_t program_num = (uint16_t)((payload[offset] << 8) | payload[offset + 1]);
        uint16_t pid = (uint16_t)(((payload[offset + 2] & 0x1F) << 8) | payload[offset + 3]);
        if (program_num != 0) {
            st->pmt_pid = pid;
            return;
        }
        offset += 4;
    }
}

static void parse_pmt(DemuxState *st, const uint8_t *payload, size_t len)
{
    if (len < 12) return;

    /* table_id(1), section_syntax+length(2), program_number(2),
       version/cni(1), section_number(1), last_section_number(1),
       PCR_PID(2), program_info_length(2) */
    uint16_t program_info_len = (uint16_t)(((payload[10] & 0x0F) << 8) | payload[11]);
    size_t offset = 12 + program_info_len;

    while (offset + 5 <= len) {
        uint8_t stream_type = payload[offset];
        uint16_t es_pid = (uint16_t)(((payload[offset + 1] & 0x1F) << 8) | payload[offset + 2]);
        uint16_t es_info_len = (uint16_t)(((payload[offset + 3] & 0x0F) << 8) | payload[offset + 4]);

        if (stream_type == STREAM_TYPE_H264 && st->video_pid == 0) {
            st->video_pid = es_pid;
            st->video_stream_type = stream_type;
        } else if ((stream_type == STREAM_TYPE_AAC || stream_type == STREAM_TYPE_MP3)
                   && st->audio_pid == 0) {
            st->audio_pid = es_pid;
            st->audio_stream_type = stream_type;
        }

        offset += 5 + es_info_len;
    }
}

int ts_demux(const uint8_t *ts_data, size_t ts_size,
             ts_frame_cb cb, void *userdata)
{
    if (!ts_data || !cb)
        return HLS2MP4_ERR_DEMUX;

    DemuxState st;
    memset(&st, 0, sizeof(st));
    st.callback = cb;
    st.userdata = userdata;

    size_t offset = 0;

    /* Sync to first TS packet */
    while (offset < ts_size && ts_data[offset] != TS_SYNC_BYTE)
        offset++;

    while (offset + TS_PACKET_SIZE <= ts_size) {
        const uint8_t *pkt = ts_data + offset;

        if (pkt[0] != TS_SYNC_BYTE) {
            offset++;
            /* Re-sync */
            while (offset < ts_size && ts_data[offset] != TS_SYNC_BYTE)
                offset++;
            continue;
        }

        /* Parse TS header */
        int transport_error = (pkt[1] >> 7) & 1;
        int payload_start   = (pkt[1] >> 6) & 1;
        uint16_t pid = (uint16_t)(((pkt[1] & 0x1F) << 8) | pkt[2]);
        int adaptation_field = (pkt[3] >> 5) & 1;
        int has_payload      = (pkt[3] >> 4) & 1;

        offset += TS_PACKET_SIZE;

        if (transport_error || pid == PID_NULL || !has_payload)
            continue;

        size_t header_size = 4;
        if (adaptation_field) {
            if (header_size >= TS_PACKET_SIZE) continue;
            uint8_t adapt_len = pkt[4];
            header_size += 1 + adapt_len;
            if (header_size >= TS_PACKET_SIZE) continue;
        }

        const uint8_t *payload = pkt + header_size;
        size_t payload_len = TS_PACKET_SIZE - header_size;

        if (pid == PID_PAT) {
            /* Skip pointer field */
            if (payload_start && payload_len > 0) {
                uint8_t pointer = payload[0];
                payload += 1 + pointer;
                if (1 + pointer >= payload_len) continue;
                payload_len -= 1 + pointer;
            }
            parse_pat(&st, payload, payload_len);
        } else if (pid == st.pmt_pid && st.pmt_pid != 0) {
            if (payload_start && payload_len > 0) {
                uint8_t pointer = payload[0];
                payload += 1 + pointer;
                if (1 + pointer >= payload_len) continue;
                payload_len -= 1 + pointer;
            }
            parse_pmt(&st, payload, payload_len);
        } else if (pid == st.video_pid && st.video_pid != 0) {
            if (payload_start) {
                /* Flush previous PES if any */
                if (st.video_pes_started && st.video_pes_size > 0)
                    flush_pes(&st, STREAM_VIDEO);
                st.video_pes_started = 1;
                st.video_pes_size = 0;
            }
            if (st.video_pes_started) {
                if (append_pes(&st.video_pes, &st.video_pes_size,
                               &st.video_pes_capacity, payload, payload_len) != 0) {
                    free(st.video_pes);
                    free(st.audio_pes);
                    return HLS2MP4_ERR_IO;
                }
            }
        } else if (pid == st.audio_pid && st.audio_pid != 0) {
            if (payload_start) {
                if (st.audio_pes_started && st.audio_pes_size > 0)
                    flush_pes(&st, STREAM_AUDIO);
                st.audio_pes_started = 1;
                st.audio_pes_size = 0;
            }
            if (st.audio_pes_started) {
                if (append_pes(&st.audio_pes, &st.audio_pes_size,
                               &st.audio_pes_capacity, payload, payload_len) != 0) {
                    free(st.video_pes);
                    free(st.audio_pes);
                    return HLS2MP4_ERR_IO;
                }
            }
        }
    }

    /* Flush remaining PES data */
    if (st.video_pes_started && st.video_pes_size > 0)
        flush_pes(&st, STREAM_VIDEO);
    if (st.audio_pes_started && st.audio_pes_size > 0)
        flush_pes(&st, STREAM_AUDIO);

    free(st.video_pes);
    free(st.audio_pes);
    return HLS2MP4_OK;
}
