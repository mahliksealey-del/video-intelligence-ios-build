import AVFoundation
import Foundation

protocol AudioExtracting: Sendable {
    func extractAudio(from videoURL: URL, to destinationURL: URL) async throws
}

struct AudioExtractor: AudioExtracting {
    func extractAudio(from videoURL: URL, to destinationURL: URL) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else { throw MediaImportError.noAudioTrack }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MediaImportError.unsupportedType
        }
        session.outputURL = destinationURL
        session.outputFileType = .m4a
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { session.cancelExport() }
        guard session.status == .completed else { throw session.error ?? CancellationError() }
    }
}
