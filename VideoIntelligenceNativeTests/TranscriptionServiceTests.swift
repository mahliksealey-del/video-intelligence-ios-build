import XCTest
@testable import VideoIntelligenceNative

private struct MockTranscriber: Transcribing {
    let output: TranscriptionOutput
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput { output }
}

final class TranscriptionServiceTests: XCTestCase {
    func testMockTranscriptionPreservesEngineModelAndTimestamps() async throws {
        let expected = TranscriptionOutput(text: "Local speech", segments: [TranscriptSegment(start: 0, end: 1.5, text: "Local speech")], engine: "Mock", model: "test")
        let result = try await MockTranscriber(output: expected).transcribe(TranscriptionRequest(audioFileURL: URL(fileURLWithPath: "/tmp/audio.m4a")))
        XCTAssertEqual(result, expected)
    }

    func testPinnedWhisperKitIdentity() {
        XCTAssertEqual(NativeTranscriptionConfiguration.packageVersion, "1.1.1")
        XCTAssertEqual(NativeTranscriptionConfiguration.packageCommit, "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4")
        XCTAssertEqual(NativeTranscriptionConfiguration.initialModel, "base.en")
        XCTAssertEqual(TranscriptionProfile(rawValue: "balanced"), .balanced)
        XCTAssertEqual(TranscriptionProfile(rawValue: "largeTurbo"), .largeTurbo)
    }
}
