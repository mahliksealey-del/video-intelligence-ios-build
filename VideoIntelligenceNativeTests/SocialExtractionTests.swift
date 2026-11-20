import XCTest
@testable import VideoIntelligenceNative

final class SocialExtractionTests: XCTestCase {
    func testProgressiveResponse() throws {
        let data = Data(#"{"ok":true,"kind":"progressive","title":"Clip","filename":"clip.mp4","media":{"url":"https://media.example/clip.mp4","headers":{"Referer":"https://example/"},"ext":"mp4","approx_bytes":42}}"#.utf8)
        guard case .ready(let media) = try SocialExtractionDecoder.listing(data), case .progressive(let track) = media.kind else { return XCTFail("Expected progressive media") }
        XCTAssertEqual(media.title, "Clip")
        XCTAssertEqual(track.url.absoluteString, "https://media.example/clip.mp4")
        XCTAssertEqual(track.approximateBytes, 42)
    }

    func testAdaptiveResponse() throws {
        let data = Data(#"{"ok":true,"kind":"adaptive","title":"Clip","video":{"url":"https://media.example/video.mp4","ext":"mp4"},"audio":{"url":"https://media.example/audio.m4a","ext":"m4a"}}"#.utf8)
        guard case .adaptive(let video, let audio) = try SocialExtractionDecoder.resolved(data).kind else { return XCTFail("Expected adaptive media") }
        XCTAssertEqual(video.fileExtension, "mp4")
        XCTAssertEqual(audio.fileExtension, "m4a")
    }

    func testFormatChoices() throws {
        let data = Data(#"{"ok":true,"kind":"choices","options":[{"height":1080,"codec":"avc1","approx_bytes":1000,"format_id":"137","adaptive":true}]}"#.utf8)
        guard case .choices(let options) = try SocialExtractionDecoder.listing(data) else { return XCTFail("Expected choices") }
        XCTAssertEqual(options.first?.formatID, "137")
        XCTAssertEqual(options.first?.height, 1080)
        XCTAssertTrue(options.first?.isAdaptive == true)
    }

    func testRestrictedResponseIsExplicit() {
        let data = Data(#"{"ok":false,"error_kind":"requires_auth","detail":"Sign in required"}"#.utf8)
        XCTAssertThrowsError(try SocialExtractionDecoder.listing(data)) { error in
            guard case SocialExtractionError.authenticationRequired = error else { return XCTFail("Expected authentication error") }
        }
    }

    @MainActor
    func testInstagramAuthDomainIsolation() async throws {
        XCTAssertTrue(InstagramSession.matchesInstagram("instagram.com"))
        XCTAssertTrue(InstagramSession.matchesInstagram(".instagram.com"))
        XCTAssertTrue(InstagramSession.matchesInstagram("www.instagram.com"))
        XCTAssertFalse(InstagramSession.matchesInstagram("evilinstagram.com"))
        XCTAssertFalse(InstagramSession.matchesInstagram("instagram.com.evil.net"))
        XCTAssertFalse(InstagramSession.matchesInstagram("tiktok.com"))
        let youtubeCookieFile = try await InstagramSession.shared.temporaryCookieFile(for: URL(string: "https://www.youtube.com/watch?v=abc")!)
        let spoofedCookieFile = try await InstagramSession.shared.temporaryCookieFile(for: URL(string: "https://instagram.com.evil.net/reel/abc")!)
        XCTAssertNil(youtubeCookieFile)
        XCTAssertNil(spoofedCookieFile)
    }

    func testTikTokUsesWorkingBrowserAsPrimaryResolver() {
        XCTAssertEqual(MediaResolutionRoute.forProvider(.tiktok), .browser)
        XCTAssertEqual(MediaResolutionRoute.forProvider(.youtube), .extractor)
        XCTAssertEqual(MediaResolutionRoute.forProvider(.instagram), .extractor)
        XCTAssertEqual(MediaResolutionRoute.forProvider(.direct), .direct)
        XCTAssertEqual(MediaResolutionRoute.forProvider(nil), .direct)
    }

    func testAllSupportedSocialLinkShapesTakeDedicatedRoute() throws {
        let cases: [(String, MediaProvider, MediaResolutionRoute)] = [
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", .youtube, .extractor),
            ("https://m.youtube.com/watch?v=dQw4w9WgXcQ", .youtube, .extractor),
            ("https://youtube.com/shorts/dQw4w9WgXcQ", .youtube, .extractor),
            ("https://www.youtube.com/shorts/dQw4w9WgXcQ?feature=share", .youtube, .extractor),
            ("https://youtu.be/dQw4w9WgXcQ", .youtube, .extractor),
            ("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", .youtube, .extractor),
            ("https://www.instagram.com/reel/example/", .instagram, .extractor),
            ("https://www.instagram.com/reels/example/", .instagram, .extractor),
            ("https://www.instagram.com/p/example/", .instagram, .extractor),
            ("https://instagr.am/p/example/", .instagram, .extractor),
            ("https://www.tiktok.com/@tester/video/7705112358586289421", .tiktok, .browser),
            ("https://vm.tiktok.com/abcd1234/", .tiktok, .browser),
            ("https://vt.tiktok.com/abcd1234/", .tiktok, .browser),
            ("https://www.tiktok.com/t/ZPNLLmuU9/", .tiktok, .browser)
        ]
        for (raw, expected, route) in cases {
            let url = try UniversalBrowserAddress.resolve(raw)
            XCTAssertEqual(MediaProvider.detect(url), expected, "Provider: \(raw)")
            XCTAssertEqual(MediaResolutionRoute.forURL(url), route, "Route: \(raw)")
        }
    }

    func testUnknownWebsitesDoNotAccidentallyBecomeSocialProviders() throws {
        for raw in [
            "https://youtube.com.evil.example/video",
            "https://youtube-nocookie.com.evil.example/embed/123",
            "https://instagr.am.evil.example/p/abc",
            "https://tiktok.com.evil.example/video/123",
            "https://videos.example.com/player"
        ] {
            let url = try MediaURLValidator.validate(raw)
            XCTAssertEqual(MediaProvider.detect(url), .direct, "Must remain generic: \(raw)")
            XCTAssertEqual(MediaResolutionRoute.forURL(url), .universalBrowser)
        }
    }

    func testProviderDetectionRejectsSuffixImpostors() throws {
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://www.tiktok.com/t/ZPNLLmuU9/")), .tiktok)
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://www.instagram.com/reel/sample/")), .instagram)
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://notinstagram.com/video")), .direct)
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://notyoutube.com/video")), .direct)
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://notiktok.com/video")), .direct)
    }

    func testTikTokBrowserCandidateIsStrictlyBoundToPostAndAllowedHost() throws {
        let good = #"{"postID":"7705112358586289421","pageID":"7705112358586289421","mediaURL":"https://v19-webapp-prime.tiktok.com/video/abc","title":"Clip","userAgent":"WebKit test"}"#
        let result = try TikTokBrowserResolution.decode(good)
        guard case .progressive(let track) = result.kind else { return XCTFail("Expected progressive video") }
        XCTAssertEqual(track.headers["Referer"], "https://www.tiktok.com/")
        XCTAssertEqual(track.headers["User-Agent"], "WebKit test")

        for json in [
            #"{"postID":"7705112358586289421","pageID":"999","mediaURL":"https://v19-webapp-prime.tiktok.com/video/abc"}"#,
            #"{"postID":"7705112358586289421","pageID":"7705112358586289421","mediaURL":"https://tiktok.com.evil.net/video/abc"}"#,
            #"{"postID":"7705112358586289421","pageID":"7705112358586289421","mediaURL":"http://v19-webapp-prime.tiktok.com/video/abc"}"#,
            #"{"postID":"7705112358586289421","pageID":"7705112358586289421","mediaURL":"blob:https://www.tiktok.com/abc"}"#
        ] {
            XCTAssertThrowsError(try TikTokBrowserResolution.decode(json))
        }
    }

    func testBrowserPrefersPlayedMediaAndCarriesAlternates() throws {
        let json = #"{"postID":"7705112358586289421","pageID":"7705112358586289421","pageURL":"https://www.tiktok.com/@tester/video/7705112358586289421","mediaURLs":["https://v19-webapp-prime.tiktok.com/playing.mp4","https://v19-webapp-prime.tiktok.com/playing.mp4","https://v19-webapp-prime.tiktok.com/alternate.mp4","https://evil.example/video.mp4"],"userAgent":"WebKit"}"#
        let media = try TikTokBrowserResolution.decode(json)
        guard case .progressive(let track) = media.kind else { return XCTFail("Expected progressive") }
        XCTAssertTrue(track.useBrowserCookies)
        XCTAssertEqual(track.url.lastPathComponent, "playing.mp4")
        XCTAssertEqual(track.alternativeURLs.count, 1)
        XCTAssertEqual(track.alternativeURLs.first?.lastPathComponent, "alternate.mp4")
        XCTAssertEqual(track.headers["Referer"], "https://www.tiktok.com/@tester/video/7705112358586289421")
    }

    func testTikTokCookieDomainSeparation() {
        XCTAssertTrue(TrackDownloadDelegate.isTikTokCookieDomain("www.tiktok.com"))
        XCTAssertTrue(TrackDownloadDelegate.isTikTokCookieDomain(".tiktok.com"))
        XCTAssertTrue(TrackDownloadDelegate.isTikTokCookieDomain("v16.tiktokcdn.com"))
        XCTAssertFalse(TrackDownloadDelegate.isTikTokCookieDomain("tiktok.com.evil.net"))
        XCTAssertFalse(TrackDownloadDelegate.isTikTokCookieDomain("www.instagram.com"))
        XCTAssertFalse(TrackDownloadDelegate.isTikTokCookieDomain("youtube.com"))
    }

    func testOrdinaryExtractorDoesNotUseBrowserCookies() throws {
        let data = Data(#"{"ok":true,"kind":"progressive","media":{"url":"https://media.example/clip.mp4"}}"#.utf8)
        let result = try SocialExtractionDecoder.resolved(data)
        guard case .progressive(let track) = result.kind else { return XCTFail("Expected progressive") }
        XCTAssertFalse(track.useBrowserCookies)
        XCTAssertTrue(track.alternativeURLs.isEmpty)
    }

    func testRejectsPrivateResolvedTrack() {
        let data = Data(#"{"ok":true,"kind":"progressive","media":{"url":"http://127.0.0.1/video.mp4","ext":"mp4"}}"#.utf8)
        XCTAssertThrowsError(try SocialExtractionDecoder.resolved(data))
    }
}
