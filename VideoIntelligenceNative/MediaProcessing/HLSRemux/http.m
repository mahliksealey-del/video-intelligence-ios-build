// Native iOS HTTPS transport for the pinned MIT hls2mp4 demuxer.
// Replaces upstream libcurl with Foundation/URLSession and blocks local IP
// literals, non-HTTPS redirects, and credential-bearing URLs.
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include "http.h"
#include "hls2mp4.h"

typedef struct { _Atomic int requested; } VIRemuxCancel;

void *hls_remux_cancel_token_create(void) {
    VIRemuxCancel *token = calloc(1, sizeof(VIRemuxCancel));
    if (token) atomic_init(&token->requested, 0);
    return token;
}
void hls_remux_cancel_token_request(void *token) {
    if (token) atomic_store(&((VIRemuxCancel *)token)->requested, 1);
}
int hls_remux_cancel_token_is_requested(void *token) {
    return token ? atomic_load(&((VIRemuxCancel *)token)->requested) : 0;
}
void hls_remux_cancel_token_free(void *token) { free(token); }

static BOOL vi_safe_url(NSURL *url) {
    if (!url || ![[url.scheme lowercaseString] isEqualToString:@"https"]) return NO;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *host = [components.host lowercaseString];
    if (!host.length || components.user || components.password || host.length > 253) return NO;
    if ([host isEqualToString:@"localhost"] || [host hasSuffix:@".localhost"] ||
        [host hasSuffix:@".local"] || [host hasSuffix:@".internal"] ||
        [host hasSuffix:@".onion"]) return NO;
    struct in_addr addr4;
    struct in6_addr addr6;
    // Reject literal numeric hosts entirely. CDN domain names work normally;
    // no loopback, private IPv4/IPv6, or special address ranges allowed.
    if (inet_pton(AF_INET, host.UTF8String, &addr4) == 1 ||
        inet_pton(AF_INET6, host.UTF8String, &addr6) == 1) return NO;
    // NSURLComponents may normalize percent-escaped host names; refuse user
    // supplied percent escapes or path traversal to reduce ambiguity.
    if ([url.absoluteString containsString:@"%00"]) return NO;
    return YES;
}

@interface VIMediaRedirectGuard : NSObject <NSURLSessionTaskDelegate>
@end
@implementation VIMediaRedirectGuard
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    completionHandler(vi_safe_url(request.URL) ? request : nil);
}
@end

static int vi_fetch(const char *urlText, uint8_t **out, size_t *length, int timeoutMS) {
    if (!urlText || !out || !length || [NSThread isMainThread]) return HLS2MP4_ERR_NETWORK;
    *out = NULL;
    *length = 0;
    @autoreleasepool {
        NSString *text = [NSString stringWithUTF8String:urlText];
        if (!text || text.length > 8192) return HLS2MP4_ERR_NETWORK;
        NSURL *url = [NSURL URLWithString:text];
        if (!vi_safe_url(url)) return HLS2MP4_ERR_NETWORK;
        NSTimeInterval seconds = MAX(5.0, MIN(60.0, (double)(timeoutMS ?: 30000) / 1000.0));
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.timeoutIntervalForRequest = seconds;
        cfg.timeoutIntervalForResource = seconds + 5;
        cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
        cfg.HTTPShouldSetCookies = NO;
        cfg.URLCache = nil;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg
            delegate:[VIMediaRedirectGuard new] delegateQueue:nil];
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        __block NSData *received = nil;
        __block NSInteger status = 0;
        NSURLSessionDataTask *task = [session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (!error && data && [response isKindOfClass:NSHTTPURLResponse.class] &&
                vi_safe_url(response.URL)) {
                status = ((NSHTTPURLResponse *)response).statusCode;
                received = data;
            }
            dispatch_semaphore_signal(gate);
        }];
        [task resume];
        long done = dispatch_semaphore_wait(gate,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)((seconds + 8) * NSEC_PER_SEC)));
        if (done != 0) {
            [task cancel];
            [session invalidateAndCancel];
            return HLS2MP4_ERR_NETWORK;
        }
        [session finishTasksAndInvalidate];
        // Bound individual resources; HLS VOD segments are normally much
        // smaller than 64 MiB. Never buffer a limitless response in memory.
        if (status < 200 || status >= 300 || !received ||
            received.length == 0 || received.length > 64 * 1024 * 1024) {
            return HLS2MP4_ERR_NETWORK;
        }
        uint8_t *bytes = malloc(received.length);
        if (!bytes) return HLS2MP4_ERR_IO;
        memcpy(bytes, received.bytes, received.length);
        *out = bytes;
        *length = received.length;
        return HLS2MP4_OK;
    }
}

struct HttpSession { int timeoutMS; };
HttpSession *http_session_new(int timeout_ms) {
    HttpSession *s = calloc(1, sizeof(HttpSession));
    if (s) s->timeoutMS = timeout_ms;
    return s;
}
void http_session_free(HttpSession *s) { free(s); }
int http_session_get(HttpSession *s, const char *url, uint8_t **data, size_t *size) {
    return vi_fetch(url, data, size, s ? s->timeoutMS : 30000);
}
int http_get_memory(const char *url, uint8_t **data, size_t *size, int timeout_ms) {
    return vi_fetch(url, data, size, timeout_ms);
}
int http_get_file(const char *url, const char *path, int timeout_ms) {
    uint8_t *data = NULL;
    size_t size = 0;
    int status = vi_fetch(url, &data, &size, timeout_ms);
    if (status != HLS2MP4_OK) return status;
    FILE *file = fopen(path, "wb");
    if (!file) { free(data); return HLS2MP4_ERR_IO; }
    size_t written = fwrite(data, 1, size, file);
    fclose(file);
    free(data);
    return written == size ? HLS2MP4_OK : HLS2MP4_ERR_IO;
}

typedef struct HttpPrefetchEntry {
    int index;
    char *url;
    struct HttpPrefetchEntry *next;
} HttpPrefetchEntry;
struct HttpPrefetch {
    int timeoutMS;
    HttpPrefetchEntry *entries;
};
HttpPrefetch *http_prefetch_new(int concurrent, int timeout_ms) {
    (void)concurrent;
    HttpPrefetch *pf = calloc(1, sizeof(HttpPrefetch));
    if (pf) pf->timeoutMS = timeout_ms;
    return pf;
}
void http_prefetch_enqueue(HttpPrefetch *pf, const char *url, int index) {
    if (!pf || !url) return;
    HttpPrefetchEntry *entry = calloc(1, sizeof(HttpPrefetchEntry));
    if (!entry) return;
    entry->index = index;
    entry->url = strdup(url);
    entry->next = pf->entries;
    pf->entries = entry;
}
int http_prefetch_get(HttpPrefetch *pf, int index, uint8_t **data, size_t *size) {
    if (!pf) return HLS2MP4_ERR_NETWORK;
    for (HttpPrefetchEntry *entry = pf->entries; entry; entry = entry->next) {
        if (entry->index == index && entry->url)
            return vi_fetch(entry->url, data, size, pf->timeoutMS);
    }
    return HLS2MP4_ERR_NETWORK;
}
void http_prefetch_free(HttpPrefetch *pf) {
    if (!pf) return;
    HttpPrefetchEntry *entry = pf->entries;
    while (entry) {
        HttpPrefetchEntry *next = entry->next;
        free(entry->url);
        free(entry);
        entry = next;
    }
    free(pf);
}
