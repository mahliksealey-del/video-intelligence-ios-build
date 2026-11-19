import AVFoundation
import Combine
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaLibraryItem] = []
    @Published var errorMessage: String?
    @Published var activeTaskID: UUID?
    @Published var storageBytes: Int64 = 0

    let storage: LibraryStorage
    let modelManager: WhisperModelManager
    private let metadata = MediaMetadataReader()
    private let extractor: AudioExtracting
    private var operation: Task<Void, Never>?

    init(storage: LibraryStorage = LibraryStorage(), extractor: AudioExtracting = AudioExtractor()) {
        self.storage = storage
        self.extractor = extractor
        self.modelManager = WhisperModelManager(storage: storage)
    }

    func load() async {
        do {
            try await storage.prepareDirectories()
            items = try await storage.loadIndex().items.sorted { $0.importedAt > $1.importedAt }
            storageBytes = await storage.storageUsage()
            await modelManager.refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func importFile(_ url: URL) async {
        do {
            guard let kind = MediaClassifier.classify(url) else { throw MediaImportError.unsupportedType }
            let id = UUID()
            let relative = try await storage.importMedia(from: url, kind: kind, id: id)
            let storedURL = try await storage.URLFor(relativePath: relative)
            let duration = try await metadata.duration(of: storedURL)
            items.insert(MediaLibraryItem(id: id, title: url.deletingPathExtension().lastPathComponent, kind: kind, sourceFilename: url.lastPathComponent, mediaRelativePath: relative, importedAt: Date(), duration: duration, status: .ready, progress: 0), at: 0)
            try await persist()
        } catch { errorMessage = error.localizedDescription }
    }

    func importPhotoData(_ data: Data, suggestedExtension: String = "mov") async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(suggestedExtension)
        do {
            try data.write(to: temporary, options: .atomic)
            await importFile(temporary)
            try? FileManager.default.removeItem(at: temporary)
        } catch { errorMessage = error.localizedDescription }
    }

    func importURL(_ value: String) {
        operation?.cancel()
        operation = Task {
            do {
                let url = try MediaURLValidator.validate(value)
                let local = try await MediaDownloader().download(from: url)
                try Task.checkCancellation()
                await importFile(local)
                try? FileManager.default.removeItem(at: local)
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func transcribe(_ item: MediaLibraryItem) {
        guard let modelFolder = modelManager.modelFolder else {
            errorMessage = "Download the base.en model in Settings before transcribing."
            return
        }
        operation?.cancel()
        activeTaskID = item.id
        update(item.id) { $0.status = .transcribing; $0.progress = 0.1; $0.errorMessage = nil }
        operation = Task {
            do {
                guard let sourcePath = item.mediaRelativePath else { throw StorageError.invalidRelativePath }
                let source = try await storage.URLFor(relativePath: sourcePath)
                let audioURL: URL
                var audioRelativePath = item.audioRelativePath
                if item.kind == .video {
                    let relative = "Audio/\(item.id.uuidString.lowercased())-extracted.m4a"
                    audioURL = try await storage.URLFor(relativePath: relative)
                    try? FileManager.default.removeItem(at: audioURL)
                    update(item.id) { $0.status = .extractingAudio; $0.progress = 0.05 }
                    try await extractor.extractAudio(from: source, to: audioURL)
                    audioRelativePath = relative
                } else {
                    audioURL = source
                }
                try Task.checkCancellation()
                update(item.id) { $0.status = .transcribing; $0.progress = 0.35; $0.audioRelativePath = audioRelativePath }
                let output = try await WhisperKitTranscriptionService(modelFolder: modelFolder).transcribe(TranscriptionRequest(audioFileURL: audioURL))
                let record = TranscriptRecord(id: item.id.uuidString, title: item.title, sourceUrl: nil, sourceName: item.sourceFilename, createdAt: ISO8601DateFormatter().string(from: Date()), duration: item.duration, engine: output.engine, model: output.model, text: output.text, correctedText: nil, segments: output.segments)
                let transcriptPath = try await storage.writeTranscript(record, id: item.id)
                update(item.id) { $0.status = .transcribed; $0.progress = 1; $0.transcriptRelativePath = transcriptPath; $0.segmentCount = output.segments.count }
                try await persist()
            } catch is CancellationError {
                update(item.id) { $0.status = .ready; $0.progress = 0 }
            } catch {
                update(item.id) { $0.status = .failed; $0.errorMessage = error.localizedDescription; $0.progress = 0 }
                try? await persist()
            }
            activeTaskID = nil
        }
    }

    func cancelOperation() { operation?.cancel(); operation = nil }

    func transcript(for item: MediaLibraryItem) async throws -> TranscriptRecord {
        guard let path = item.transcriptRelativePath else { throw CocoaError(.fileNoSuchFile) }
        return try await storage.loadTranscript(relativePath: path)
    }

    func saveCorrection(_ text: String, for item: MediaLibraryItem) async throws -> TranscriptRecord {
        let record = try await transcript(for: item)
        let updated = TranscriptRecord(id: record.id, title: record.title, sourceUrl: record.sourceUrl, sourceName: record.sourceName, createdAt: record.createdAt, duration: record.duration, engine: record.engine, model: record.model, text: record.text, correctedText: text, segments: record.segments)
        _ = try await storage.writeTranscript(updated, id: item.id)
        return updated
    }

    func deleteMedia(_ item: MediaLibraryItem) async { try? await storage.deleteMedia(for: item); update(item.id) { $0.mediaRelativePath = nil; $0.audioRelativePath = nil }; try? await persist() }

    func deleteItem(_ item: MediaLibraryItem) async { try? await storage.deleteItemFiles(for: item); items.removeAll { $0.id == item.id }; try? await persist() }

    func deleteAll() async { for item in items { try? await storage.deleteItemFiles(for: item) }; items = []; try? await persist() }

    func clearCaches() async { try? await storage.clearCaches(); storageBytes = await storage.storageUsage() }

    private func update(_ id: UUID, mutation: (inout MediaLibraryItem) -> Void) { guard let index = items.firstIndex(where: { $0.id == id }) else { return }; mutation(&items[index]) }

    private func persist() async throws { try await storage.saveIndex(MediaLibraryIndex(items: items)); storageBytes = await storage.storageUsage() }
}
