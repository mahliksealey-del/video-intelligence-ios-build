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
    case medium
    case largeFull
    case largeTurbo

    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        case .medium: return "Medium (English)"
        case .largeFull: return "Large V3 (Full Precision)"
        case .largeTurbo: return "Large V3 Turbo (Compressed)"
        }
    }
    var model: String {
        switch self {
        case .fast, .balanced: return "base.en"
        case .accurate: return "small.en"
        case .medium: return "medium.en"
        // Include the full repository folder name so WhisperKit's glob resolver
        // cannot accidentally select a similarly named quantized or Turbo model.
        case .largeFull: return "openai_whisper-large-v3"
        // Argmax's compact, 4-bit Core ML Large-v3-Turbo variant.
        case .largeTurbo: return "large-v3-v20240930_626MB"
        }
    }
    var detail: String {
        switch self {
        case .fast: return "base.en with minimal fallback — fastest"
        case .balanced: return "base.en with English decoding and recovery"
        case .accurate: return "small.en — greater accuracy, modest memory use"
        case .medium: return "Medium.en — full-size English model (~1.53 GB), optional on-device download."
        case .largeFull: return "Original Large V3, full-precision Core ML (~3.09 GB). Experimental on 8 GB+ iPhones: slower, warmer, and may fail under memory pressure."
        case .largeTurbo: return "Large V3 Turbo is a different, faster model checkpoint, compressed to ~626 MB. Accuracy can vary by recording."
        }
    }
}

/// Conservative device and storage preflight for opt-in speech models. This
/// isn't a measured performance guarantee; tested devices may vary.
enum TranscriptionModelRequirements {
    static let largeTurbo = "large-v3-v20240930_626MB"
    static let largeFull = "openai_whisper-large-v3"

    static func minimumMemoryBytes(for model: String) -> UInt64 {
        switch model {
        case largeTurbo, largeFull: return 8_000_000_000
        default: return 0
        }
    }

    static func canRun(model: String, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        physicalMemory >= minimumMemoryBytes(for: model)
    }

    static func requiredFreeStorageBytes(for model: String) -> Int64 {
        // Extra headroom for compiled Core ML assets, download staging and cache.
        switch model {
        case largeFull: return 8_000_000_000
        case largeTurbo: return 3_000_000_000
        case "medium.en": return 4_000_000_000
        case "small.en": return 1_500_000_000
        default: return 600_000_000
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

