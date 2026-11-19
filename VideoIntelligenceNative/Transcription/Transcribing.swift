import Foundation

struct TranscriptionRequest: Sendable {
    let audioFileURL: URL
}

struct TranscriptionOutput: Sendable, Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let engine: String
    let model: String
    var performance: TranscriptionPerformance? = nil
}

struct TranscriptionPerformance: Codable, Sendable, Equatable {
    let modelInitializationSeconds: Double
    let inferenceSeconds: Double
    let totalSeconds: Double
    let wasWarm: Bool
}

enum TranscriptionProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case accurate

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var model: String {
        switch self {
        case .fast, .balanced: return "base.en"
        case .accurate: return "small.en"
        }
    }
    var detail: String {
        switch self {
        case .fast: return "base.en with minimal fallback"
        case .balanced: return "base.en with English decoding and recovery"
        case .accurate: return "small.en for higher quality; uses more storage and memory"
        }
    }
}

protocol Transcribing: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput
}

enum NativeTranscriptionConfiguration {
    static let packageURL = "https://github.com/argmaxinc/argmax-oss-swift.git"
    static let packageVersion = "1.1.1"
    static let packageCommit = "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4"
    static let product = "WhisperKit"
    static let initialModel = "base.en"
}

