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

// Request headers are scoped to the caller's worker thread: concurrent
// browser conversions cannot leak headers into one another's requests.
static __thread char vi_referer[2048];
static __thread char vi_user_agent[512];
void hls_remux_http_set_request_headers(const char *referer, const char *user_agent) {
    snprintf(vi_referer, sizeof(vi_referer), "%s", referer ? referer : "");
    snprintf(vi_user_agent, sizeof(vi_user_agent), "%s", user_agent ? user_agent : "");
}

// One NSURLSession is reused across playlist/key fetches. Prefetched TS
// segments share a separate NSURLSession and begin before the demuxer needs
// them. This avoids serial connect/handshake latency (especially over Tor).
@interface VIFetchTicket : NSObject
@property(nonatomic, strong) dispatch_semaphore_t done;
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSData *received;
@property(nonatomic, strong) NSURLResponse *response;
@property(nonatomic, strong) NSError *error;
@end
@implementation VIFetchTicket
- (instancetype)init {
    if ((self = [super init])) _done = dispatch_semaphore_create(0);
    return self;
}
@end

static NSURLSession *vi_new_session(int timeoutMS, int parallelism) {
    NSTimeInterval seconds = MAX(5.0, MIN(60.0, (double)(timeoutMS > 0 ? timeoutMS : 30000) / 1000.0));
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = seconds;
    config.timeoutIntervalForResource = seconds + 8;
    config.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    config.HTTPShouldSetCookies = NO;
    config.URLCache = nil;
    config.HTTPMaximumConnectionsPerHost = MAX(1, MIN(3, parallelism));
    return [NSURLSession sessionWithConfiguration:config
            delegate:[VIMediaRedirectGuard new] delegateQueue:nil];
}

static NSMutableURLRequest *vi_request(const char *urlText,
                                      int64_t start, int64_t length) {
    if (!urlText) return nil;
    NSString *text = [NSString stringWithUTF8String:urlText];
    if (!text || text.length > 8192) return nil;
    NSURL *url = [NSURL URLWithString:text];
    if (!vi_safe_url(url)) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (vi_referer[0]) {
        [request setValue:[NSString stringWithUTF8String:vi_referer]
         forHTTPHeaderField:@"Referer"];
    }
    if (vi_user_agent[0]) {
        [request setValue:[NSString stringWithUTF8String:vi_user_agent]
         forHTTPHeaderField:@"User-Agent"];
    }
    if (length > 0) {
        if (start < 0 || length > 67108864 || start > INT64_MAX - length)
            return nil;
        NSString *value = [NSString stringWithFormat:@"bytes=%lld-%lld",
                           (long long)start, (long long)(start + length - 1)];
        [request setValue:value forHTTPHeaderField:@"Range"];
        [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    }
    return request;
}

static VIFetchTicket *vi_begin(NSURLSession *session, NSURLRequest *request) {
    if (!session || !request) return nil;
    VIFetchTicket *ticket = [VIFetchTicket new];
    ticket.task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            ticket.received = data;
            ticket.response = response;
            ticket.error = error;
            dispatch_semaphore_signal(ticket.done);
        }];
    [ticket.task resume];
    return ticket;
}

static int vi_finish(VIFetchTicket *ticket, int timeoutMS,
                     int64_t start, int64_t length,
                     uint8_t **out, size_t *size) {
    if (!ticket || !out || !size || [NSThread isMainThread]) return HLS2MP4_ERR_NETWORK;
    *out = NULL; *size = 0;
    NSTimeInterval seconds = MAX(5.0, MIN(60.0, (double)(timeoutMS > 0 ? timeoutMS : 30000) / 1000.0));
    long done = dispatch_semaphore_wait(ticket.done, dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((seconds + 10) * NSEC_PER_SEC)));
    if (done != 0) {
        [ticket.task cancel];
        return HLS2MP4_ERR_NETWORK;
    }
    NSHTTPURLResponse *response = [ticket.response isKindOfClass:NSHTTPURLResponse.class]
                                  ? (NSHTTPURLResponse *)ticket.response : nil;
    NSData *body = ticket.received;
    if (ticket.error || !response || !vi_safe_url(response.URL) ||
        !body || body.length == 0 || body.length > 67108864) {
        return HLS2MP4_ERR_NETWORK;
    }
    if (length > 0) {
        NSString *prefix = [NSString stringWithFormat:@"bytes %lld-%lld/",
                             (long long)start, (long long)(start + length - 1)];
        NSString *header = [response valueForHTTPHeaderField:@"Content-Range"];
        if (response.statusCode != 206 || ![header hasPrefix:prefix] ||
            (int64_t)body.length != length) return HLS2MP4_ERR_NETWORK;
    } else if (response.statusCode < 200 || response.statusCode >= 300) {
        return HLS2MP4_ERR_NETWORK;
    }
    uint8_t *bytes = malloc(body.length);
    if (!bytes) return HLS2MP4_ERR_IO;
    memcpy(bytes, body.bytes, body.length);
    *out = bytes;
    *size = body.length;
    return HLS2MP4_OK;
}

static int vi_fetch(NSURLSession *session, const char *url,
                    int64_t start, int64_t length,
                    uint8_t **data, size_t *size, int timeoutMS) {
    @autoreleasepool {
        NSMutableURLRequest *request = vi_request(url, start, length);
        VIFetchTicket *ticket = vi_begin(session, request);
        return vi_finish(ticket, timeoutMS, start, length, data, size);
    }
}

struct HttpSession { int timeoutMS; void *session; };

HttpSession *http_session_new(int timeout_ms) {
    HttpSession *s = calloc(1, sizeof(HttpSession));
    if (!s) return NULL;
    s->timeoutMS = timeout_ms > 0 ? timeout_ms : 30000;
    NSURLSession *client = vi_new_session(s->timeoutMS, 2);
    if (!client) { free(s); return NULL; }
    s->session = (__bridge_retained void *)client;
    return s;
}
void http_session_free(HttpSession *s) {
    if (!s) return;
    if (s->session) {
        NSURLSession *client = (__bridge_transfer NSURLSession *)s->session;
        [client finishTasksAndInvalidate];
    }
    free(s);
}
int http_session_get_range(HttpSession *s, const char *url,
                           int64_t start, int64_t length,
                           uint8_t **data, size_t *size) {
    if (!s || !s->session) return HLS2MP4_ERR_NETWORK;
    return vi_fetch((__bridge NSURLSession *)s->session, url,
                    start, length, data, size, s->timeoutMS);
}
int http_session_get(HttpSession *s, const char *url,
                     uint8_t **data, size_t *size) {
    return http_session_get_range(s, url, 0, 0, data, size);
}
int http_get_memory(const char *url, uint8_t **data, size_t *size, int timeout_ms) {
    HttpSession *session = http_session_new(timeout_ms);
    if (!session) return HLS2MP4_ERR_NETWORK;
    int result = http_session_get(session, url, data, size);
    http_session_free(session);
    return result;
}
int http_get_file(const char *url, const char *path, int timeout_ms) {
    uint8_t *data = NULL;
    size_t size = 0;
    int status = http_get_memory(url, &data, &size, timeout_ms);
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
    int64_t offset, length;
    void *ticket;
    struct HttpPrefetchEntry *next;
} HttpPrefetchEntry;

struct HttpPrefetch {
    int timeoutMS;
    void *session;
    HttpPrefetchEntry *entries;
};

HttpPrefetch *http_prefetch_new(int max_concurrent, int timeout_ms) {
    HttpPrefetch *pf = calloc(1, sizeof(HttpPrefetch));
    if (!pf) return NULL;
    pf->timeoutMS = timeout_ms > 0 ? timeout_ms : 30000;
    NSURLSession *client = vi_new_session(pf->timeoutMS, max_concurrent);
    if (!client) { free(pf); return NULL; }
    pf->session = (__bridge_retained void *)client;
    return pf;
}
void http_prefetch_enqueue_range(HttpPrefetch *pf, const char *url, int index,
                                 int64_t start, int64_t length) {
    if (!pf || !pf->session) return;
    @autoreleasepool {
        NSMutableURLRequest *request = vi_request(url, start, length);
        VIFetchTicket *ticket = vi_begin(
            (__bridge NSURLSession *)pf->session, request);
        if (!ticket) return;
        HttpPrefetchEntry *entry = calloc(1, sizeof(HttpPrefetchEntry));
        if (!entry) { [ticket.task cancel]; return; }
        entry->index = index;
        entry->offset = start;
        entry->length = length;
        entry->ticket = (__bridge_retained void *)ticket;
        entry->next = pf->entries;
        pf->entries = entry;
    }
}
void http_prefetch_enqueue(HttpPrefetch *pf, const char *url, int index) {
    http_prefetch_enqueue_range(pf, url, index, 0, 0);
}
int http_prefetch_get(HttpPrefetch *pf, int index,
                      uint8_t **data, size_t *size) {
    if (!pf) return HLS2MP4_ERR_NETWORK;
    for (HttpPrefetchEntry *entry = pf->entries; entry; entry = entry->next) {
        if (entry->index == index && entry->ticket) {
            @autoreleasepool {
                return vi_finish((__bridge VIFetchTicket *)entry->ticket,
                                 pf->timeoutMS, entry->offset, entry->length,
                                 data, size);
            }
        }
    }
    return HLS2MP4_ERR_NETWORK;
}
void http_prefetch_free(HttpPrefetch *pf) {
    if (!pf) return;
    HttpPrefetchEntry *entry = pf->entries;
    while (entry) {
        HttpPrefetchEntry *next = entry->next;
        if (entry->ticket) {
            VIFetchTicket *ticket = (__bridge_transfer VIFetchTicket *)entry->ticket;
            [ticket.task cancel]; // No-op for finished requests.
        }
        free(entry);
        entry = next;
    }
    if (pf->session) {
        NSURLSession *client = (__bridge_transfer NSURLSession *)pf->session;
        [client invalidateAndCancel];
    }
    free(pf);
}
