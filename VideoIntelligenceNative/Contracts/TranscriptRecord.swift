import Foundation

struct TranscriptSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct TranscriptRecord: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceUrl: String?
    let sourceName: String?
    let createdAt: String
    let duration: Double
    let engine: String
    let model: String
    let text: String
    let correctedText: String?
    let segments: [TranscriptSegment]
}
