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

    func testRejectsPrivateResolvedTrack() {
        let data = Data(#"{"ok":true,"kind":"progressive","media":{"url":"http://127.0.0.1/video.mp4","ext":"mp4"}}"#.utf8)
        XCTAssertThrowsError(try SocialExtractionDecoder.resolved(data))
    }
}
