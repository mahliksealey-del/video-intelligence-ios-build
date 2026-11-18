import Foundation

enum TranscriptValidationError: Error, Equatable {
    case invalidDuration
    case invalidTimestamp(index: Int)
    case timestampOutsideMedia(index: Int)
    case nonMonotonicTimestamp(index: Int)
}

extension TranscriptRecord {
    func validateTimestamps(tolerance: Double = 0.001) throws {
        guard duration.isFinite, duration >= 0 else {
            throw TranscriptValidationError.invalidDuration
        }

        var previousStart = -Double.infinity
        for (index, segment) in segments.enumerated() {
            guard segment.start.isFinite,
                  segment.end.isFinite,
                  segment.start >= 0,
                  segment.end >= segment.start else {
                throw TranscriptValidationError.invalidTimestamp(index: index)
            }
            guard segment.end <= duration + tolerance else {
                throw TranscriptValidationError.timestampOutsideMedia(index: index)
            }
            guard segment.start >= previousStart else {
                throw TranscriptValidationError.nonMonotonicTimestamp(index: index)
            }
            previousStart = segment.start
        }
    }
}
