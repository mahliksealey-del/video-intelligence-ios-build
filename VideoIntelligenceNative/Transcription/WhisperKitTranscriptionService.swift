import Combine
import Foundation
import WhisperKit

enum ModelState: Equatable, Sendable {
    case notDownloaded
    case downloading(Double)
    case ready
    case failed(String)
}

@MainActor
final class WhisperModelManager: ObservableObject {
    @Published private(set) var state: ModelState = .notDownloaded
    private let storage: LibraryStorage
    private(set) var modelFolder: URL?

    init(storage: LibraryStorage) { self.storage = storage }

    func refresh() async {
        let base = await storage.modelDirectory
        if let child = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).first(where: { $0.hasDirectoryPath }) {
            modelFolder = child
            state = .ready
        } else {
            state = .notDownloaded
        }
    }

    func download() async {
        state = .downloading(0)
        let base = await storage.modelDirectory
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let folder = try await WhisperKit.download(variant: NativeTranscriptionConfiguration.initialModel, downloadBase: base) { progress in
                Task { @MainActor in self.state = .downloading(progress.fractionCompleted) }
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableFolder = folder
            try? mutableFolder.setResourceValues(values)
            modelFolder = folder
            state = .ready
        } catch is CancellationError {
            state = .notDownloaded
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

actor WhisperKitTranscriptionService: Transcribing {
    private let modelFolder: URL
    private var whisperKit: WhisperKit?

    init(modelFolder: URL) { self.modelFolder = modelFolder }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        try Task.checkCancellation()
        let engine: WhisperKit
        if let loaded = whisperKit {
            engine = loaded
        } else {
            let config = WhisperKitConfig(model: NativeTranscriptionConfiguration.initialModel, modelFolder: modelFolder.path, verbose: false, prewarm: true, load: true, download: false)
            let loaded = try await WhisperKit(config)
            whisperKit = loaded
            engine = loaded
        }
        let input = AudioInputOptions(audioLoadingMode: .incremental(chunkDurationSeconds: 60, maxBufferedChunks: 1))
        let results = try await engine.transcribe(audioPath: request.audioFileURL.path, audioInputOptions: input)
        try Task.checkCancellation()
        let segments = results.flatMap(\.segments).map {
            TranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return TranscriptionOutput(text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), segments: segments, engine: "WhisperKit 1.1.1", model: NativeTranscriptionConfiguration.initialModel)
    }
}
