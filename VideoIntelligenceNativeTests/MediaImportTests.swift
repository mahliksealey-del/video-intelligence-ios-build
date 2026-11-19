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
}
