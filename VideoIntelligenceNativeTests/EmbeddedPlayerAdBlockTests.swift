import Foundation
import WebKit
import XCTest
@testable import VideoIntelligenceNative

final class EmbeddedPlayerAdBlockTests: XCTestCase {
    func testNestedFrameResultRecognizesRealPlayingVideo() throws {
        let payload = #"""
        {"nonce":"E7F8F79D-D739-42F1-A89B-A1F3EE59CB5F",
         "pageURL":"https://player.example.com/embed/clip",
         "title":"My embedded clip",
         "userAgent":"WebKit test",
         "candidates":[
           {"url":"https://media.example.com/video.mp4?token=x","kind":"direct","playing":true},
           {"url":"https://media.example.com/master.m3u8","kind":"hls","playing":false},
           {"url":"https://player.example.com/watch/clip","kind":"embed","playing":false}
         ]}
        """#
        let result = try UniversalMediaFrameResult.decode(
            payload, frameURL: URL(string: "https://player.example.com/embed/clip")!,
            expectedNonce: "E7F8F79D-D739-42F1-A89B-A1F3EE59CB5F"
        )
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.first?.kind, .direct)
        XCTAssertTrue(result.first?.isPlaying == true)
        XCTAssertEqual(result.first?.pageURL.host, "player.example.com")
        XCTAssertEqual(result.last?.kind, .embed)
    }

    func testFrameResultRequiresWebKitFrameOriginAndCorrectScan() {
        let payload = #"""
        {"nonce":"E7F8F79D-D739-42F1-A89B-A1F3EE59CB5F",
         "pageURL":"https://player.example.com/embed/clip",
         "candidates":[{"url":"https://cdn.example.com/a.mp4","kind":"direct"}]}
        """#
        XCTAssertThrowsError(try UniversalMediaFrameResult.decode(
            payload, frameURL: URL(string: "https://ads.example.com/")!,
            expectedNonce: "E7F8F79D-D739-42F1-A89B-A1F3EE59CB5F"))
        XCTAssertThrowsError(try UniversalMediaFrameResult.decode(
            payload, frameURL: URL(string: "https://player.example.com/")!,
            expectedNonce: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    }

    func testFrameRejectsLocalNetworkAndUnsafeMediaURLs() throws {
        let payload = #"""
        {"nonce":"E7F8F79D-D739-42F1-A89B-A1F3EE59CB5F",
         "pageURL":"https://player.example.com/embed/clip",
         "candidates":[
           {"url":"http://127.0.0.1/secret.mp4","kind":"direct"},
           {"url":"https://127.0.0.1/secret.mp4","kind":"direct"},
           {"url":"blob:https://player.example.com/abc","kind":"direct"},
           {"url":"https://cdn.example.com/real.mp4","kind":"direct"}
         ]}
        """#
        let result = try UniversalMediaFrameResult.decode(
            payload, frameURL: URL(string: "https://player.example.com/")!,
            expectedNonce: "E7F8F79D-D739-42F1-A89B-A1F3EE59CB5F")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.url.lastPathComponent, "real.mp4")
    }

    func testMergePrefersActualPlayingDirectStreamOverIframeLink() {
        let origin = URL(string: "https://blog.example.com/")!
        let embedded = URL(string: "https://player.example.com/clip")!
        let generic = UniversalWebMediaCandidate(url: embedded, pageURL: origin,
            title: "Blog", userAgent: nil, kind: .embed, isPlaying: false)
        let direct = UniversalWebMediaCandidate(
            url: URL(string: "https://media.example.com/a.mp4")!,
            pageURL: embedded, title: "Player", userAgent: nil,
            kind: .direct, isPlaying: true)
        let result = UniversalMediaFrameResult.merge([generic], [direct, direct])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].url, direct.url)
        XCTAssertEqual(result[1].kind, .embed)
    }

    func testInjectedProbeUsesAllFramesAndDoesNotReadCredentials() {
        let script = UniversalMediaFrameProbe.script
        XCTAssertTrue(script.contains("vi.scan.v1"))
        XCTAssertTrue(script.contains("messageHandlers.viFrameMedia"))
        XCTAssertTrue(script.contains("iframe"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
    }

    func testStayOnSiteStopsCrossSiteNavigationButAllowsEmbeds() {
        let page = URL(string: "https://forum.example.com/thread/123")!
        let ad = URL(string: "https://ads.example.net/click?redirect=true")!
        let sameSite = URL(string: "https://forum.example.com/thread/124")!
        XCTAssertTrue(VideoSiteNavigationLock.shouldBlock(currentPage: page, nextPage: ad,
                                                          isMainFrame: true, enabled: true))
        XCTAssertFalse(VideoSiteNavigationLock.shouldBlock(currentPage: page, nextPage: ad,
                                                           isMainFrame: false, enabled: true))
        XCTAssertFalse(VideoSiteNavigationLock.shouldBlock(currentPage: page, nextPage: sameSite,
                                                           isMainFrame: true, enabled: true))
        XCTAssertFalse(VideoSiteNavigationLock.shouldBlock(currentPage: page, nextPage: ad,
                                                           isMainFrame: true, enabled: false))
    }

    func testNativeAdRulesJSONExcludesMediaAndFirstParty() throws {
        let data = Data(NativeAdBlocker.rulesJSON.utf8)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rules.count, NativeAdBlocker.adHosts.count)
        XCTAssertGreaterThan(rules.count, 10)
        for rule in rules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let loads = try XCTUnwrap(trigger["load-type"] as? [String])
            XCTAssertEqual(loads, ["third-party"])
            let resources = try XCTUnwrap(trigger["resource-type"] as? [String])
            XCTAssertFalse(resources.contains("media"))
            XCTAssertFalse(resources.contains("document"))
            XCTAssertNotNil(trigger["url-filter"] as? String)
        }
    }

    func testAdDomainRulesRejectSuffixImpostors() throws {
        let data = Data(NativeAdBlocker.rulesJSON.utf8)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let first = try XCTUnwrap(rules.first?["trigger"] as? [String: Any])
        let pattern = try XCTUnwrap(first["url-filter"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ url: String) -> Bool {
            regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
        }
        XCTAssertTrue(matches("https://ads.doubleclick.net/view/ad.js"))
        XCTAssertTrue(matches("https://doubleclick.net/view/ad.js"))
        XCTAssertFalse(matches("https://doubleclick.net.evil.example/ad.js"))
        XCTAssertFalse(matches("https://notdoubleclick.net/ad.js"))
    }

    func testNativeAdRulesCompileInWebKit() {
        let compiled = expectation(description: "native ad rule list compiled")
        guard let store = WKContentRuleListStore.default() else {
            return XCTFail("WebKit content rule store unavailable in the simulator")
        }
        store.compileContentRuleList(
            forIdentifier: "VideoIntelligenceAdBlockTests",
            encodedContentRuleList: NativeAdBlocker.rulesJSON
        ) { rule, error in
            XCTAssertNil(error, "WebKit rejected the ad-filter rules")
            XCTAssertNotNil(rule)
            compiled.fulfill()
        }
        wait(for: [compiled], timeout: 15)
    }
}
