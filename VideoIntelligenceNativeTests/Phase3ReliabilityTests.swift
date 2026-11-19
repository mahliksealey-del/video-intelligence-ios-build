import XCTest
@testable import VideoIntelligenceNative

final class Phase3ReliabilityTests: XCTestCase {
    func testWordErrorRateIsDeterministic() {
        XCTAssertEqual(AccuracyBenchmark.wordErrorRate(reference: "the quick brown fox", hypothesis: "the quick fox"), 0.25, accuracy: 0.0001)
        XCTAssertEqual(AccuracyBenchmark.wordErrorRate(reference: "Hello, WORLD!", hypothesis: "hello world"), 0)
        XCTAssertEqual(AccuracyBenchmark.wordErrorRate(reference: "", hypothesis: ""), 0)
    }

    func testProfilesSelectExpectedModels() {
        XCTAssertEqual(TranscriptionProfile.fast.model, "base.en")
        XCTAssertEqual(TranscriptionProfile.balanced.model, "base.en")
        XCTAssertEqual(TranscriptionProfile.accurate.model, "small.en")
    }

    func testModelValidationRejectsIncompleteAndAcceptsRequiredFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertThrowsError(try WhisperModelValidator.validate(folder: root))
        for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        XCTAssertNoThrow(try WhisperModelValidator.validate(folder: root))
    }

    @MainActor
    func testPlaybackClockFormatting() {
        XCTAssertEqual(MediaPlayerView.clock(0), "00:00")
        XCTAssertEqual(MediaPlayerView.clock(65.9), "01:05")
        XCTAssertEqual(MediaPlayerView.clock(-4), "00:00")
    }
}
