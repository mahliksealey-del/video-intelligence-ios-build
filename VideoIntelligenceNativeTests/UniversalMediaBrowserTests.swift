import XCTest
@testable import VideoIntelligenceNative

final class UniversalMediaBrowserTests: XCTestCase {
    func testUnknownWebsitesUseBrowserButDirectMediaIsPreserved() throws {
        XCTAssertEqual(MediaResolutionRoute.forURL(try MediaURLValidator.validate("https://forum.example.com/thread/123")), .universalBrowser)
        XCTAssertEqual(MediaResolutionRoute.forURL(try MediaURLValidator.validate("https://files.example.org/clip.mp4?sig=xyz")), .direct)
        XCTAssertEqual(MediaResolutionRoute.forURL(try MediaURLValidator.validate("https://files.example.org/audio.m4a")), .direct)
        XCTAssertEqual(MediaResolutionRoute.forURL(try MediaURLValidator.validate("https://www.youtube.com/watch?v=123")), .extractor)
        XCTAssertEqual(MediaResolutionRoute.forURL(try MediaURLValidator.validate("https://www.instagram.com/reel/123")), .extractor)
        XCTAssertEqual(MediaResolutionRoute.forURL(try MediaURLValidator.validate("https://www.tiktok.com/@user/video/123")), .browser)
    }

    func testBrowserDetectsPlayingVideoAndStreamTypes() throws {
        let json = #"""
        {"pageURL":"https://forum.example.com/thread/1","title":"My private test thread",
         "userAgent":"WebKit iOS",
         "candidates":[
           {"url":"https://cdn.example.com/video/master.m3u8","kind":"hls","playing":false},
           {"url":"https://forum.example.com/stream.mp4?sig=abc","kind":"direct","playing":true},
           {"url":"https://cdn.example.com/video/manifest.mpd","kind":"dash","playing":false},
           {"url":"https://forum.example.com/stream.mp4?sig=abc","kind":"direct","playing":false}
         ]}
        """#
        let page = URL(string: "https://forum.example.com/thread/1")!
        let candidates = try UniversalWebMediaResolver.decode(json, expectedPageURL: page)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].kind, .direct)
        XCTAssertTrue(candidates[0].isPlaying)
        XCTAssertEqual(candidates[1].kind, .hls)
        XCTAssertEqual(candidates[2].kind, .dash)
        XCTAssertEqual(candidates[0].title, "My private test thread")
    }

    func testBrowserRejectsPrivateAndBlobMediaWithoutLeakingCookies() throws {
        let json = #"""
        {"pageURL":"https://forum.example.com/thread/1","candidates":[
           {"url":"blob:https://forum.example.com/secret","kind":"direct","playing":true},
           {"url":"https://127.0.0.1/secret.mp4","kind":"direct","playing":true},
           {"url":"https://forum.example.com.evil.net/stream.mp4","kind":"direct","playing":true},
           {"url":"https://cdn.example.com/video.mp4","kind":"direct","playing":true}
         ]}
        """#
        let page = URL(string: "https://forum.example.com/thread/1")!
        let result = try UniversalWebMediaResolver.decode(json, expectedPageURL: page)
        XCTAssertEqual(result.count, 2)  // Unrelated cross-origin media may be public, but no forum cookies are sent.
        XCTAssertTrue(result.contains(where: { $0.url.host == "cdn.example.com" }))
    }

    func testBrowserRejectsSpoofedPageOrigin() {
        let page = URL(string: "https://forum.example.com/thread/1")!
        let spoof = #"{"pageURL":"https://evil.example.net/","candidates":[{"url":"https://media.example.net/v.mp4","kind":"direct"}]}"#
        XCTAssertThrowsError(try UniversalWebMediaResolver.decode(spoof, expectedPageURL: page))
    }

    func testHLSDetectionIsNotAdvertisedAsExportableMP4() throws {
        let candidate = UniversalWebMediaCandidate(
            url: URL(string: "https://cdn.example.net/master.m3u8")!,
            pageURL: URL(string: "https://forum.example.com/thread/1")!,
            title: "Stream", userAgent: nil, kind: .hls, isPlaying: true
        )
        XCTAssertThrowsError(try UniversalWebMediaResolver.resolved(candidate))
    }

    func testBrowserTransferNeverSendsTokenBearingPageAsReferer() throws {
        let candidate = UniversalWebMediaCandidate(
            url: URL(string: "https://media.example.com/v.mp4?token=abc")!,
            pageURL: URL(string: "https://forum.example.com/thread/secret?access=hidden")!,
            title: "Video", userAgent: "Test User Agent", kind: .direct, isPlaying: true
        )
        let result = try UniversalWebMediaResolver.resolved(candidate)
        guard case .progressive(let track) = result.kind else {
            return XCTFail("Expected progressive")
        }
        XCTAssertEqual(track.browserSessionOrigin?.host, "forum.example.com")
        XCTAssertEqual(track.headers["Referer"], "https://forum.example.com/")
        XCTAssertFalse(track.useBrowserCookies) // TikTok-only flag stays separate.
        XCTAssertEqual(track.headers["User-Agent"], "Test User Agent")
    }

    func testSharedCookieRequiresBothPageAndMediaDomainMatch() {
        XCTAssertTrue(TrackDownloadDelegate.cookieDomain(".example.com", matches: "forum.example.com"))
        XCTAssertTrue(TrackDownloadDelegate.cookieDomain(".example.com", matches: "media.example.com"))
        XCTAssertFalse(TrackDownloadDelegate.cookieDomain(".example.com", matches: "evil-example.com"))
        XCTAssertFalse(TrackDownloadDelegate.cookieDomain(".forum.example.com", matches: "cdn.example.com"))
        XCTAssertFalse(TrackDownloadDelegate.cookieDomain(".example.com", matches: "example.com.evil.net"))
    }
}
