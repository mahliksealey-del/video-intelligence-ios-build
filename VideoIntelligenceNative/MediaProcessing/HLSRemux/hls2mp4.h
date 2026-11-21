#pragma once
#include <stdint.h>

typedef enum {
    HLS2MP4_OK            =  0,
    HLS2MP4_ERR_NETWORK   = -1,
    HLS2MP4_ERR_PARSE     = -2,
    HLS2MP4_ERR_DEMUX     = -3,
    HLS2MP4_ERR_DECRYPT   = -4,
    HLS2MP4_ERR_MUXER     = -5,
    HLS2MP4_ERR_IO        = -6,
    HLS2MP4_ERR_CANCELED  = -7,
} hls2mp4_error;

typedef void (*hls2mp4_progress_cb)(int segments_done, int segments_total, void *userdata);
typedef void (*hls2mp4_log_cb)(const char *message, void *userdata);

typedef struct {
    const char           *input_url;       /* URL to .m3u8 playlist */
    const char           *output_path;     /* Local path for output .mp4 */
    hls2mp4_progress_cb   on_progress;     /* Optional, may be NULL */
    hls2mp4_log_cb        on_log;          /* Optional, may be NULL */
    void                 *userdata;        /* Passed to callbacks */
    int                   timeout_ms;      /* HTTP timeout, 0 = default (10000) */
    int                   max_retries;     /* Per-segment retry count, 0 = default (3) */
    void                 *cancel_token;   /* Atomic cancellation signal; may be NULL */
} hls2mp4_options;

int         hls2mp4_convert(const hls2mp4_options *opts);
const char *hls2mp4_error_string(int code);

/* Safe cancellation token shared with Swift Task cancellation. */
void *hls_remux_cancel_token_create(void);
void  hls_remux_cancel_token_request(void *token);
int   hls_remux_cancel_token_is_requested(void *token);
void  hls_remux_cancel_token_free(void *token);
