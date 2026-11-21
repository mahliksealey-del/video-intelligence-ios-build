import XCTest
@testable import VideoIntelligenceNative

final class UniversalMediaBrowserTests: XCTestCase {
    func testEditableAddressBarAcceptsHostnamesPathsAndPorts() throws {
        XCTAssertEqual(
            try UniversalBrowserAddress.resolve("example.org/watch?v=42").absoluteString,
            "https://example.org/watch?v=42"
        )
        XCTAssertEqual(
            try UniversalBrowserAddress.resolve(" https://www.example.org/clip ").absoluteString,
            "https://www.example.org/clip"
        )
        XCTAssertEqual(
            try UniversalBrowserAddress.resolve("example.org:8443/player").absoluteString,
            "https://example.org:8443/player"
        )
        XCTAssertEqual(
            try UniversalBrowserAddress.resolve("http://example.org/watch").scheme,
            "http"
        )
    }

    func testEditableAddressBarRejectsUnsafeOrInvalidURLs() {
        for entry in [
            "", "   ", "javascript:alert(1)", "file:///private/video.mp4",
            "ftp://example.org/file.mp4", "http://127.0.0.1/video",
            "http://192.168.1.4/player", "https://localhost/video",
            "example.org/a path", "https://admin:secret@example.org/private"
        ] {
            XCTAssertThrowsError(try UniversalBrowserAddress.resolve(entry),
                                 "Should reject unsafe address: \(entry)")
        }
    }

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

    func testPlayingHLSNowOffersOfflineDownloadWithoutPretendingItsMP4() {
        let hls = UniversalWebMediaCandidate(
            url: URL(string: "https://hls-cdn77.example.com/video/playlist.m3u8?signature=abc")!,
            pageURL: URL(string: "https://website.example.com/watch/9")!,
            title: "Playing video",
            userAgent: nil,
            kind: .hls,
            isPlaying: true
        )
        XCTAssertTrue(HLSOfflineDownloadService.supports(hls))
        XCTAssertEqual(MediaClassifier.classify(URL(fileURLWithPath: "/tmp/stream.movpkg")), .video)
        // Native offline HLS packages are not direct MP4 video files.
        XCTAssertThrowsError(try UniversalWebMediaResolver.resolved(hls))

        let dash = UniversalWebMediaCandidate(
            url: URL(string: "https://cdn.example.com/manifest.mpd")!,
            pageURL: hls.pageURL,
            title: hls.title,
            userAgent: nil,
            kind: .dash,
            isPlaying: true
        )
        XCTAssertFalse(HLSOfflineDownloadService.supports(dash))

        let spoofed = UniversalWebMediaCandidate(
            url: URL(string: "https://127.0.0.1/private.m3u8")!,
            pageURL: hls.pageURL,
            title: hls.title,
            userAgent: nil,
            kind: .hls,
            isPlaying: false
        )
        XCTAssertFalse(HLSOfflineDownloadService.supports(spoofed))
    }

    func testHLSDetectionIsNotAdvertisedAsExportableMP4() throws {
        let candidate = UniversalWebMediaCandidate(
            url: URL(string: "https://cdn.example.net/master.m3u8")!,
            pageURL: URL(string: "https://forum.example.com/thread/1")!,
            title: "Stream", userAgent: nil, kind: .hls, isPlaying: true
        )
        XCTAssertThrowsError(try UniversalWebMediaResolver.resolved(candidate))
    }

    func testPlaybackAudioSessionUsesNoRecordingOnlyRoutingOptions() {
        // Apple says AirPlay and A2DP route automatically under .playback.
        // .allowAirPlay/.allowBluetoothA2DP can fail with OSStatus -50.
        XCTAssertEqual(MediaPlaybackAudioPolicy.category, .playback)
        XCTAssertEqual(MediaPlaybackAudioPolicy.mode, .moviePlayback)
        XCTAssertTrue(MediaPlaybackAudioPolicy.options.isEmpty)
    }

    func testBrowserQueueLimitsActiveTransfersToTwo() {
        func job(_ state: BrowserDownloadStatus) -> BrowserDownloadJob {
            BrowserDownloadJob(
                id: UUID(), title: "Video", host: "cdn.example.org",
                queuedAt: Date(), startedAt: nil, status: state,
                progress: 0, savedItemID: nil, errorMessage: nil)
        }
        let queue = [job(.completed), job(.queued), job(.queued), job(.queued)]
        XCTAssertEqual(BrowserDownloadQueuePolicy.maxConcurrent, 2)
        XCTAssertEqual(BrowserDownloadQueuePolicy.nextQueuedIndex(in: queue, activeCount: 0), 3)
        XCTAssertEqual(BrowserDownloadQueuePolicy.nextQueuedIndex(in: queue, activeCount: 1), 3)
        XCTAssertNil(BrowserDownloadQueuePolicy.nextQueuedIndex(in: queue, activeCount: 2))
        XCTAssertNil(BrowserDownloadQueuePolicy.nextQueuedIndex(
            in: [job(.failed), job(.canceled), job(.completed)], activeCount: 0))
    }

    func testPosterOnlyBelongsToCandidateWithPlayerAssociation() throws {
        let json = #"""
        {"pageURL":"https://feed.example.org/watch",
         "candidates":[
           {"url":"https://cdn.example.org/active.m3u8","kind":"hls","playing":true,
            "poster":"https://cdn.example.org/thumb1.jpg"},
           {"url":"https://cdn.example.org/other.m3u8","kind":"hls","playing":false},
           {"url":"https://cdn.example.org/direct.mp4","kind":"direct","playing":false,
            "poster":"https://127.0.0.1/secret.jpg"}
         ]}
        """#
        let candidates = try UniversalWebMediaResolver.decode(
            json, expectedPageURL: URL(string: "https://feed.example.org/watch")!)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].posterURL?.lastPathComponent, "thumb1.jpg")
        XCTAssertNil(candidates[1].posterURL)
        XCTAssertNil(candidates[2].posterURL)
        XCTAssertTrue(UniversalWebMediaResolver.script.contains("video.poster"))
        XCTAssertTrue(UniversalMediaFrameProbe.script.contains("player.poster"))
    }

    func testCrossOriginFramePreservesValidatedPlayerPoster() throws {
        let json = #"""
        {"nonce":"00000000-0000-0000-0000-000000000001",
         "pageURL":"https://embed.example.org/clip",
         "candidates":[{"url":"https://cdn.example.org/a.m3u8","kind":"hls",
                        "playing":true,"poster":"https://embed.example.org/poster.jpg"}]}
        """#
        let result = try UniversalMediaFrameResult.decode(
            json, frameURL: URL(string: "https://embed.example.org/clip")!,
            expectedNonce: "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(result.first?.posterURL?.lastPathComponent, "poster.jpg")
        let prior = UniversalWebMediaCandidate(
            url: result[0].url, pageURL: result[0].pageURL, title: result[0].title,
            userAgent: nil, kind: .hls, isPlaying: false)
        XCTAssertNotNil(UniversalMediaFrameResult.merge([prior], result)[0].posterURL)
    }

    func testPlayingVideoFocusFindsActiveMiddleStreamInsteadOfGuessingFirst() throws {
        let json = #"""
        {"pageURL":"https://feed.example.org/stream",
         "candidates":[
          {"url":"https://cdn.example.org/old.m3u8","kind":"hls","playing":false},
          {"url":"https://cdn.example.org/visible.m3u8","kind":"hls","playing":true,
           "poster":"https://cdn.example.org/visible-poster.jpg","association":"player"},
          {"url":"https://cdn.example.org/next.m3u8","kind":"hls","playing":false}
         ]}
        """#
        let items = try UniversalWebMediaResolver.decode(
            json, expectedPageURL: URL(string: "https://feed.example.org/stream")!)
        let preferred = UniversalMediaFocus.preferred(items)
        XCTAssertEqual(preferred.count, 1)
        XCTAssertEqual(preferred[0].url.lastPathComponent, "visible.m3u8")
        XCTAssertEqual(preferred[0].association, .player)
    }

    func testNoArbitraryHLSSelectionWhenSeveralStreamsAreUnlinked() throws {
        let json = #"""
        {"pageURL":"https://feed.example.org/stream",
         "candidates":[
          {"url":"https://cdn.example.org/one.m3u8","kind":"hls","playing":false},
          {"url":"https://cdn.example.org/two.m3u8","kind":"hls","playing":false},
          {"url":"https://cdn.example.org/three.m3u8","kind":"hls","playing":false}
         ]}
        """#
        let candidates = try UniversalWebMediaResolver.decode(
            json, expectedPageURL: URL(string: "https://feed.example.org/stream")!)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertTrue(UniversalMediaFocus.preferred(candidates).isEmpty)
    }

    func testPossibleAssociationMustBeUniqueAndCannotClaimCertainPlayback() throws {
        let json = #"""
        {"pageURL":"https://feed.example.org/stream",
         "candidates":[
          {"url":"https://cdn.example.org/old.m3u8","kind":"hls","playing":false},
          {"url":"https://cdn.example.org/possible.m3u8","kind":"hls","playing":false,
           "association":"possible"}
         ]}
        """#
        let items = try UniversalWebMediaResolver.decode(
            json, expectedPageURL: URL(string: "https://feed.example.org/stream")!)
        let preferred = UniversalMediaFocus.preferred(items)
        XCTAssertEqual(preferred.count, 1)
        XCTAssertEqual(preferred[0].association, .possible)
        XCTAssertFalse(preferred[0].isPlaying)
        let other = UniversalWebMediaCandidate(
            url: URL(string: "https://cdn.example.org/another.m3u8")!,
            pageURL: items[0].pageURL, title: "Other",
            userAgent: nil, kind: .hls, isPlaying: false,
            association: .possible)
        XCTAssertTrue(UniversalMediaFocus.preferred(items + [other]).isEmpty)
    }

    func testOneUnlinkedStreamIsNeverAdvertisedAsConfirmedPlaying() throws {
        let json = #"""
        {"pageURL":"https://feed.example.org/watch/one",
         "candidates":[
          {"url":"https://cdn.example.org/one.m3u8","kind":"hls","playing":false}
         ]}
        """#
        let items = try UniversalWebMediaResolver.decode(
            json, expectedPageURL: URL(string: "https://feed.example.org/watch/one")!)
        XCTAssertEqual(UniversalMediaFocus.preferred(items).count, 1)
        XCTAssertEqual(items[0].association, .unknown)
        XCTAssertFalse(items[0].isPlaying)
        XCTAssertTrue(UniversalMediaFrameProbe.script.contains("activePlayers.length === 1"))
    }

    func testPiPCaptureTakesPriorityOverOtherPlayingFrame() throws {
        let one = BrowserSelectedPlayer(
            frameURL: URL(string: "https://embed.example.org/a")!,
            pageURL: URL(string: "https://embed.example.org/a")!,
            streamURL: URL(string: "https://cdn.example.org/first.m3u8")!,
            posterURL: nil, redGifsClipID: nil,
            isPiP: false, isPlaying: true, title: "First", userAgent: nil)
        let pip = BrowserSelectedPlayer(
            frameURL: URL(string: "https://embed.example.org/b")!,
            pageURL: URL(string: "https://embed.example.org/b")!,
            streamURL: URL(string: "https://cdn.example.org/second.m3u8")!,
            posterURL: nil, redGifsClipID: nil,
            isPiP: true, isPlaying: true, title: "Second", userAgent: nil)
        XCTAssertEqual(BrowserPlayerSelectionPolicy.single([one, pip]), pip)
        XCTAssertNil(BrowserPlayerSelectionPolicy.single([one, oneChangedSource(one)]))
        XCTAssertNil(BrowserPlayerSelectionPolicy.single([pip, oneChangedSource(pip)]))
    }

    private func oneChangedSource(_ source: BrowserSelectedPlayer) -> BrowserSelectedPlayer {
        BrowserSelectedPlayer(
            frameURL: source.frameURL, pageURL: source.pageURL,
            streamURL: URL(string: "https://cdn.example.org/different.mp4")!,
            posterURL: nil, redGifsClipID: nil,
            isPiP: source.isPiP, isPlaying: source.isPlaying,
            title: "Different", userAgent: nil)
    }

    func testFrameCaptureDecodesOnlyRealActivePlayerNotResourceList() throws {
        let nonce = "00000000-0000-0000-0000-000000000001"
        let frame = URL(string: "https://www.redgifs.com/browse")!
        let json = #"""
        {"nonce":"00000000-0000-0000-0000-000000000001",
         "pageURL":"https://www.redgifs.com/browse",
         "title":"Feed",
         "candidates":[
           {"url":"https://api.redgifs.com/old.m3u8","kind":"hls"},
           {"url":"https://api.redgifs.com/new.m3u8","kind":"hls"}],
         "selectedPlayer":{"mediaURL":"blob:https://www.redgifs.com/opaque",
                           "redGifsClipID":"HotpinkAcrobatickitfox",
                           "isPiP":true,"isPlaying":true}}
        """#
        let selection = try XCTUnwrap(
            UniversalMediaFrameResult.decodeSelectedPlayer(
                json, frameURL: frame, expectedNonce: nonce))
        XCTAssertEqual(selection.redGifsClipID, "HotpinkAcrobatickitfox")
        XCTAssertTrue(selection.isPiP)
        XCTAssertNil(selection.streamURL)
        XCTAssertNil(selection.directCandidate)
        XCTAssertEqual(selection.clipPageURL?.path,
                       "/watch/HotpinkAcrobatickitfox")
        XCTAssertNil(BrowserPlayerSelectionPolicy.single([]))
    }

    func testUntrustedPlayerMetadataCannotPretendToBeRedGifsClip() throws {
        let nonce = "00000000-0000-0000-0000-000000000001"
        let json = #"""
        {"nonce":"00000000-0000-0000-0000-000000000001",
         "pageURL":"https://unrelated.example.org/watch",
         "candidates":[],
         "selectedPlayer":{"mediaURL":"javascript:alert(1)",
                           "redGifsClipID":"ignored",
                           "isPiP":false,"isPlaying":true}}
        """#
        let selection = try XCTUnwrap(UniversalMediaFrameResult.decodeSelectedPlayer(
            json, frameURL: URL(string: "https://unrelated.example.org/watch")!,
            expectedNonce: nonce))
        XCTAssertNil(selection.redGifsClipID)
        XCTAssertNil(selection.streamURL)
        XCTAssertNil(selection.directCandidate)
        XCTAssertThrowsError(try UniversalMediaFrameResult.decodeSelectedPlayer(
            json, frameURL: URL(string: "https://evil.example.com")!,
            expectedNonce: nonce))
        XCTAssertThrowsError(try UniversalMediaFrameResult.decodeSelectedPlayer(
            json, frameURL: URL(string: "https://unrelated.example.org/watch")!,
            expectedNonce: "different"))
    }

    func testPublicClipMetadataSourceSafetyAndPiPInstrumentation() {
        XCTAssertTrue(RedGifsSelectedClipResolver.validID("SqueakyHelplessWisent"))
        XCTAssertFalse(RedGifsSelectedClipResolver.validID("../unsafe"))
        XCTAssertFalse(RedGifsSelectedClipResolver.validID("x"))
        XCTAssertNil(RedGifsSelectedClipResolver.decodedMediaURL("http://127.0.0.1/secret.mp4"))
        XCTAssertNil(RedGifsSelectedClipResolver.decodedMediaURL("javascript:alert(1)"))
        XCTAssertEqual(RedGifsSelectedClipResolver.decodedMediaURL(
            "https://cdn.example.org/file.mp4")?.lastPathComponent, "file.mp4")
        XCTAssertTrue(UniversalMediaFrameProbe.script.contains("enterpictureinpicture"))
        XCTAssertTrue(UniversalMediaFrameProbe.script.contains("webkitpresentationmodechanged"))
        XCTAssertTrue(UniversalMediaFrameProbe.script.contains("sourceClipID(player)"))
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

    func testPopupsRequireUserInitiatedSafeNavigation() {
        XCTAssertTrue(UniversalBrowserPopupPolicy.canOpenNewWindow(
            URL(string: "https://video.example.com/watch"), userInitiated: true))
        XCTAssertFalse(UniversalBrowserPopupPolicy.canOpenNewWindow(
            URL(string: "https://video.example.com/advertisement"), userInitiated: false))
        XCTAssertFalse(UniversalBrowserPopupPolicy.canOpenNewWindow(
            URL(string: "https://localhost/video"), userInitiated: true))
        XCTAssertFalse(UniversalBrowserPopupPolicy.canOpenNewWindow(
            URL(string: "http://video.example.com/watch"), userInitiated: true))
        XCTAssertFalse(UniversalBrowserPopupPolicy.canOpenNewWindow(nil, userInitiated: true))
    }

    func testPopupDismissalIsExplicitAndLimitedToCloseControls() {
        let script = UniversalBrowserPopupPolicy.dismissScript
        XCTAssertTrue(script.contains("dismiss"))
        XCTAssertTrue(script.contains("not now"))
        XCTAssertTrue(script.contains("captcha"))
        XCTAssertTrue(script.contains("button.click()"))
        XCTAssertFalse(script.contains("localStorage.clear()"))
    }

    func testSharedCookieRequiresBothPageAndMediaDomainMatch() {
        XCTAssertTrue(TrackDownloadDelegate.cookieDomain(".example.com", matches: "forum.example.com"))
        XCTAssertTrue(TrackDownloadDelegate.cookieDomain(".example.com", matches: "media.example.com"))
        XCTAssertFalse(TrackDownloadDelegate.cookieDomain(".example.com", matches: "evil-example.com"))
        XCTAssertFalse(TrackDownloadDelegate.cookieDomain(".forum.example.com", matches: "cdn.example.com"))
        XCTAssertFalse(TrackDownloadDelegate.cookieDomain(".example.com", matches: "example.com.evil.net"))
    }
}
