import Foundation

struct TranscriptionRequest: Sendable {
    let audioFileURL: URL
}

struct TranscriptionOutput: Sendable, Equatable {
    let text: String
    let segments: [TranscriptSegment]
    let engine: String
    let model: String
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

