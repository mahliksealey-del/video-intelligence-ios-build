#ifndef HTTP_H
#define HTTP_H

#include <stddef.h>
#include <stdint.h>

/* Single-request API (creates+destroys a CURL handle each time) */
int http_get_memory(const char *url, uint8_t **out_data, size_t *out_size, int timeout_ms);
int http_get_file(const char *url, const char *path, int timeout_ms);

/* Session-based API (reuses CURL handle for connection pooling) */
typedef struct HttpSession HttpSession;

HttpSession *http_session_new(int timeout_ms);
void         http_session_free(HttpSession *s);
int          http_session_get(HttpSession *s, const char *url,
                              uint8_t **out_data, size_t *out_size);

/* Prefetch pipeline: download multiple URLs concurrently */
typedef struct HttpPrefetch HttpPrefetch;

HttpPrefetch *http_prefetch_new(int max_concurrent, int timeout_ms);
void          http_prefetch_free(HttpPrefetch *pf);

/* Enqueue a URL for background download. index is a caller-assigned ID. */
void http_prefetch_enqueue(HttpPrefetch *pf, const char *url, int index);

/* Get the result for a given index. Blocks until that transfer completes.
   Returns HLS2MP4_OK on success. Caller must free *out_data. */
int  http_prefetch_get(HttpPrefetch *pf, int index,
                       uint8_t **out_data, size_t *out_size);

#endif /* HTTP_H */
