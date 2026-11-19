import XCTest
@testable import VideoIntelligenceNative

final class MediaImportTests: XCTestCase {
    func testClassifiesSupportedVideoAndAudioExtensions() {
        XCTAssertEqual(MediaClassifier.classify(URL(fileURLWithPath: "/tmp/sample.MP4")), .video)
        XCTAssertEqual(MediaClassifier.classify(URL(fileURLWithPath: "/tmp/sample.mov")), .video)
        XCTAssertEqual(MediaClassifier.classify(URL(fileURLWithPath: "/tmp/sample.m4a")), .audio)
        XCTAssertEqual(MediaClassifier.classify(URL(fileURLWithPath: "/tmp/sample.WAV")), .audio)
    }

    func testRejectsUnknownFileType() {
        XCTAssertNil(MediaClassifier.classify(URL(fileURLWithPath: "/tmp/sample.txt")))
    }

    func testDirectURLValidation() throws {
        XCTAssertEqual(try MediaURLValidator.validate(" https://example.com/sample.mp4 ").absoluteString, "https://example.com/sample.mp4")
        XCTAssertThrowsError(try MediaURLValidator.validate("file:///tmp/video.mp4"))
        XCTAssertThrowsError(try MediaURLValidator.validate("not a url"))
    }

    func testBlocksLocalNetworkDestinations() {
        for value in ["http://localhost/video.mp4", "http://127.0.0.1/video.mp4", "http://192.168.1.5/video.mp4", "http://10.0.0.2/video.mp4", "http://169.254.169.254/latest"] {
            XCTAssertThrowsError(try MediaURLValidator.validate(value))
        }
    }

    func testDetectsSocialProvidersWithoutClaimingDirectMedia() throws {
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://youtu.be/example")), .youtube)
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://www.tiktok.com/@user/video/1")), .tiktok)
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://instagram.com/reel/example")), .instagram)
        XCTAssertEqual(MediaProvider.detect(try MediaURLValidator.validate("https://cdn.example.com/video.mp4")), .direct)
    }
}
