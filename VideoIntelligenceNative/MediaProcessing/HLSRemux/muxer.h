#ifndef MUXER_H
#define MUXER_H

#include <stddef.h>
#include <stdint.h>

typedef struct Muxer Muxer;

Muxer *muxer_open(const char *path);

int    muxer_set_video_params(Muxer *m, const uint8_t *sps, size_t sps_size,
                                        const uint8_t *pps, size_t pps_size,
                                        int width, int height);

int    muxer_set_audio_params(Muxer *m, int sample_rate,
                              int channels, int aac_profile);

/* dts_90k/pts_90k: timestamps in 90kHz units (from TS PES header) */
int    muxer_write_video(Muxer *m, const uint8_t *data,
                         size_t size, int64_t dts_90k, int64_t pts_90k,
                         int is_keyframe);
int    muxer_write_audio(Muxer *m, const uint8_t *data,
                         size_t size, int64_t dts_90k);

int    muxer_close(Muxer *m);
void   muxer_free(Muxer *m);

#endif /* MUXER_H */
