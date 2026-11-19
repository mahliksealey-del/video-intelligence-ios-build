import Foundation

enum MediaKind: String, Codable, CaseIterable, Sendable {
    case video
    case audio
}

enum ProcessingStatus: String, Codable, Sendable {
    case ready
    case extractingAudio
    case transcribing
    case transcribed
    case failed
}

struct MediaLibraryItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    let kind: MediaKind
    let sourceFilename: String
    var sourceURL: String? = nil
    var mediaRelativePath: String?
    var audioRelativePath: String?
    var transcriptRelativePath: String?
    let importedAt: Date
    let duration: Double
    var status: ProcessingStatus
    var progress: Double
    var errorMessage: String?

    var segmentCount: Int = 0
    var lastPerformance: TranscriptionPerformance? = nil
}

struct MediaLibraryIndex: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var items: [MediaLibraryItem] = []
}
