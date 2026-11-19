import XCTest
@testable import VideoIntelligenceNative

final class TranscriptExportTests: XCTestCase {
    func testSRTUsesValidSequentialTimecodes() {
        let exporter = TranscriptExporter(storage: LibraryStorage())
        let output = exporter.srt(fixture())
        XCTAssertEqual(output, "1\n00:00:00,000 --> 00:00:01,250\nHello\n\n2\n00:01:01,500 --> 00:01:03,000\nworld.\n")
    }

    func testCorrectedTextIsPreferredWithoutChangingSegments() {
        let exporter = TranscriptExporter(storage: LibraryStorage())
        XCTAssertEqual(exporter.displayText(fixture(correctedText: "Hello, corrected world.")), "Hello, corrected world.")
        XCTAssertEqual(fixture(correctedText: "changed").segments.count, 2)
    }

    func testJSONExportPreservesContract() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = LibraryStorage(documentsURL: root.appendingPathComponent("Documents"), applicationSupportURL: root.appendingPathComponent("Support"), cachesURL: root.appendingPathComponent("Caches"))
        let transcript = fixture(correctedText: "Corrected")
        let url = try await TranscriptExporter(storage: storage).export(transcript, format: .json)
        XCTAssertEqual(try JSONDecoder.transcript.decode(TranscriptRecord.self, from: Data(contentsOf: url)), transcript)
    }

    private func fixture(correctedText: String? = nil) -> TranscriptRecord {
        TranscriptRecord(id: "test", title: "Sample", sourceUrl: nil, sourceName: "sample.m4a", createdAt: "2026-11-18T12:00:00Z", duration: 63, engine: "WhisperKit 1.1.1", model: "base.en", text: "Hello world.", correctedText: correctedText, segments: [TranscriptSegment(start: 0, end: 1.25, text: " Hello "), TranscriptSegment(start: 61.5, end: 63, text: "world.")])
    }
}
