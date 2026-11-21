#ifndef TS_DEMUX_H
#define TS_DEMUX_H

#include <stddef.h>
#include <stdint.h>

typedef enum { STREAM_VIDEO, STREAM_AUDIO } StreamType;

typedef struct {
    StreamType  type;
    uint8_t    *data;
    size_t      size;
    int64_t     pts;   /* in 90kHz units, -1 if absent */
    int64_t     dts;   /* in 90kHz units, -1 if absent */
} TsFrame;

typedef void (*ts_frame_cb)(const TsFrame *frame, void *userdata);

int ts_demux(const uint8_t *ts_data, size_t ts_size,
             ts_frame_cb cb, void *userdata);

#endif /* TS_DEMUX_H */
