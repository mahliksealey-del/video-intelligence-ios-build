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
        XCTAssertEqual(TranscriptionProfile.medium.model, "medium.en")
        XCTAssertEqual(TranscriptionProfile.largeFull.model, "openai_whisper-large-v3")
        XCTAssertEqual(TranscriptionProfile.largeTurbo.model, "large-v3-v20240930_626MB")
        XCTAssertEqual(Set(TranscriptionProfile.allCases.map(\.model)).count, 5)
    }

    func testOptionalModelsAreNeverRequiredForDefaultProfiles() {
        XCTAssertEqual(TranscriptionProfile.fast.model, NativeTranscriptionConfiguration.initialModel)
        XCTAssertTrue(TranscriptionModelRequirements.canRun(model: "base.en", physicalMemory: 1_000_000_000))
        XCTAssertTrue(TranscriptionModelRequirements.canRun(model: "small.en", physicalMemory: 1_000_000_000))
        XCTAssertTrue(TranscriptionModelRequirements.canRun(model: "medium.en", physicalMemory: 6_000_000_000))
    }

    func testLargeTurboMemoryAndStoragePreflight() {
        let model = TranscriptionProfile.largeTurbo.model
        XCTAssertFalse(TranscriptionModelRequirements.canRun(model: model, physicalMemory: 6_000_000_000))
        XCTAssertTrue(TranscriptionModelRequirements.canRun(model: model, physicalMemory: 8_000_000_000))
        XCTAssertTrue(TranscriptionModelRequirements.canRun(model: model, physicalMemory: 12_000_000_000))
        XCTAssertGreaterThan(TranscriptionModelRequirements.requiredFreeStorageBytes(for: "medium.en"),
                             TranscriptionModelRequirements.requiredFreeStorageBytes(for: "small.en"))
        XCTAssertGreaterThan(TranscriptionModelRequirements.requiredFreeStorageBytes(for: model), 600_000_000)
        let full = TranscriptionProfile.largeFull.model
        XCTAssertFalse(TranscriptionModelRequirements.canRun(model: full, physicalMemory: 6_000_000_000))
        XCTAssertTrue(TranscriptionModelRequirements.canRun(model: full, physicalMemory: 8_000_000_000))
        XCTAssertTrue(TranscriptionModelRequirements.canRun(model: full, physicalMemory: 12_000_000_000))
        XCTAssertGreaterThan(TranscriptionModelRequirements.requiredFreeStorageBytes(for: full),
                             TranscriptionModelRequirements.requiredFreeStorageBytes(for: model))
    }

    func testFullLargeModelCannotBeConfusedWithCompressedOrTurboCacheFolders() {
        let full = TranscriptionProfile.largeFull.model
        XCTAssertTrue(WhisperModelValidator.matchesModelDirectory("openai_whisper-large-v3", selectedModel: full))
        XCTAssertFalse(WhisperModelValidator.matchesModelDirectory("openai_whisper-large-v3_947MB", selectedModel: full))
        XCTAssertFalse(WhisperModelValidator.matchesModelDirectory("openai_whisper-large-v3_turbo_954MB", selectedModel: full))
        XCTAssertFalse(WhisperModelValidator.matchesModelDirectory("openai_whisper-large-v3-v20240930_626MB", selectedModel: full))
        XCTAssertTrue(WhisperModelValidator.matchesModelDirectory("openai_whisper-large-v3-v20240930_626MB", selectedModel: TranscriptionProfile.largeTurbo.model))
        XCTAssertTrue(WhisperModelValidator.matchesModelDirectory("openai_whisper-medium.en", selectedModel: TranscriptionProfile.medium.model))
        XCTAssertTrue(WhisperModelValidator.matchesModelDirectory("openai_whisper-base.en", selectedModel: TranscriptionProfile.fast.model))
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
