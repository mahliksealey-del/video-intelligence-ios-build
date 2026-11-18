import XCTest
@testable import VideoIntelligenceNative

final class TranscriptTimestampTests: XCTestCase {
    func testAcceptsOrderedTimestampsWithinDuration() throws {
        let record = makeRecord(segments: [
            TranscriptSegment(start: 0, end: 1.5, text: "One"),
            TranscriptSegment(start: 1.5, end: 3, text: "Two")
        ])

        XCTAssertNoThrow(try record.validateTimestamps())
    }

    func testRejectsNegativeOrReversedTimestamp() {
        let record = makeRecord(segments: [TranscriptSegment(start: 2, end: 1, text: "Invalid")])

        XCTAssertThrowsError(try record.validateTimestamps()) { error in
            XCTAssertEqual(error as? TranscriptValidationError, .invalidTimestamp(index: 0))
        }
    }

    func testRejectsTimestampPastMediaDuration() {
        let record = makeRecord(segments: [TranscriptSegment(start: 59, end: 61, text: "Too late")])

        XCTAssertThrowsError(try record.validateTimestamps()) { error in
            XCTAssertEqual(error as? TranscriptValidationError, .timestampOutsideMedia(index: 0))
        }
    }

    func testRejectsNonMonotonicSegmentStarts() {
        let record = makeRecord(segments: [
            TranscriptSegment(start: 5, end: 6, text: "Later"),
            TranscriptSegment(start: 4, end: 7, text: "Earlier")
        ])

        XCTAssertThrowsError(try record.validateTimestamps()) { error in
            XCTAssertEqual(error as? TranscriptValidationError, .nonMonotonicTimestamp(index: 1))
        }
    }

    private func makeRecord(segments: [TranscriptSegment]) -> TranscriptRecord {
        TranscriptRecord(
            id: "test",
            title: "Test",
            sourceUrl: nil,
            sourceName: "test.m4a",
            createdAt: "2026-11-18T00:00:00Z",
            duration: 60,
            engine: "test",
            model: "base.en",
            text: "Test",
            correctedText: nil,
            segments: segments
        )
    }
}
