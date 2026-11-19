import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum MediaImportError: LocalizedError, Equatable {
    case unsupportedType
    case inaccessibleFile
    case noAudioTrack

    var errorDescription: String? {
        switch self {
        case .unsupportedType: return "This file is not a supported audio or video format."
        case .inaccessibleFile: return "The selected file could not be accessed. Try copying it to Files and importing again."
        case .noAudioTrack: return "This video has no audio track to transcribe."
        }
    }
}

enum MediaClassifier {
    static let videoExtensions = Set(["mp4", "mov", "m4v"])
    static let audioExtensions = Set(["m4a", "mp3", "wav", "aac", "caf", "aif", "aiff"])

    static func classify(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
        }
        return nil
    }
}

enum SecurityScopedAccess {
    static func withAccess<T>(to url: URL, operation: () throws -> T) throws -> T {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard accessed || FileManager.default.isReadableFile(atPath: url.path) else {
            throw MediaImportError.inaccessibleFile
        }
        return try operation()
    }
}

struct MediaMetadataReader {
    func duration(of url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return duration.seconds.isFinite ? max(0, duration.seconds) : 0
    }
}
