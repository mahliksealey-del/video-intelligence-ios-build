import Combine
import Foundation
import WhisperKit

enum ModelAvailability: Equatable, Sendable {
    case unavailable
    case downloading(Double)
    case downloaded
    case validated
    case loaded
    case failed(String)
}

struct InstalledModel: Identifiable, Equatable, Sendable {
    let name: String
    let folder: URL
    let bytes: Int64
    var state: ModelAvailability
    var id: String { name }
}

enum ModelValidationError: LocalizedError {
    case incomplete(String)
    case insufficientStorage(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .incomplete(let name): return "The \(name) model download is incomplete. Retry the download. Your other working models were preserved."
        case .insufficientStorage(let required, let available): return "Not enough free storage. The model needs about \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)); \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        }
    }
}

enum WhisperModelValidator {
    static let requiredPrefixes = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    static func validate(folder: URL, fileManager: FileManager = .default) throws {
        guard let enumerator = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { throw ModelValidationError.incomplete(folder.lastPathComponent) }
        let names = enumerator.compactMap { ($0 as? URL)?.lastPathComponent }
        guard requiredPrefixes.allSatisfy({ prefix in names.contains(where: { $0.hasPrefix(prefix) }) }) else { throw ModelValidationError.incomplete(folder.lastPathComponent) }
    }
}

@MainActor
final class WhisperModelManager: ObservableObject {
    @Published private(set) var models: [String: InstalledModel] = [:]
    @Published private(set) var downloadStartedAt: [String: Date] = [:]
    @Published var selectedProfile: TranscriptionProfile {
        didSet { UserDefaults.standard.set(selectedProfile.rawValue, forKey: "transcriptionProfile") }
    }
    private let storage: LibraryStorage
    private let diagnostics: DiagnosticLogger
    private var downloadTask: Task<Void, Never>?

    init(storage: LibraryStorage) {
        self.storage = storage
        self.diagnostics = DiagnosticLogger(applicationSupportURL: storage.applicationSupportURL)
        self.selectedProfile = TranscriptionProfile(rawValue: UserDefaults.standard.string(forKey: "transcriptionProfile") ?? "") ?? .balanced
    }

    var selectedModel: InstalledModel? { models[selectedProfile.model] }
    var modelFolder: URL? { guard let model = selectedModel, model.state == .validated || model.state == .loaded else { return nil }; return model.folder }

    func refresh() async {
        let base = await storage.modelDirectory
        var discovered: [String: InstalledModel] = [:]
        for name in Set(TranscriptionProfile.allCases.map(\.model)) {
            if let folder = findModel(named: name, beneath: base) {
                do {
                    try WhisperModelValidator.validate(folder: folder)
                    discovered[name] = InstalledModel(name: name, folder: folder, bytes: directorySize(folder), state: .validated)
                } catch {
                    discovered[name] = InstalledModel(name: name, folder: folder, bytes: directorySize(folder), state: .failed(error.localizedDescription))
                    await diagnostics.record(stage: "model-validation", message: "Model \(name) failed validation", error: error)
                }
            } else {
                discovered[name] = InstalledModel(name: name, folder: base.appendingPathComponent(name), bytes: 0, state: .unavailable)
            }
        }
        models = discovered
    }

    func download(_ name: String) {
        downloadTask?.cancel()
        downloadStartedAt[name] = Date()
        setState(name, .downloading(0))
        downloadTask = Task {
            let base = await storage.modelDirectory
            do {
                try checkStorage(for: name, at: base)
                let folder = try await WhisperKit.download(variant: name, downloadBase: base) { progress in
                    Task { @MainActor in self.setState(name, .downloading(progress.fractionCompleted)) }
                }
                try Task.checkCancellation()
                setState(name, .downloaded)
                try WhisperModelValidator.validate(folder: folder)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var mutable = folder; try? mutable.setResourceValues(values)
                models[name] = InstalledModel(name: name, folder: folder, bytes: directorySize(folder), state: .validated)
                await diagnostics.record(stage: "model-download", message: "Validated model \(name)")
            } catch is CancellationError {
                await refresh()
                await diagnostics.record(stage: "model-download", message: "Cancelled model \(name)")
            } catch {
                setState(name, .failed(error.localizedDescription))
                await diagnostics.record(stage: "model-download", message: "Failed model \(name)", error: error)
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel(); downloadTask = nil }

    func delete(_ name: String) async throws {
        guard let model = models[name], model.state != .loaded else { return }
        try FileManager.default.removeItem(at: model.folder)
        await diagnostics.record(stage: "model-delete", message: "Deleted model \(name)")
        await refresh()
    }

    func diagnosticsURL() async -> URL? { await diagnostics.exportURL() }

    private func setState(_ name: String, _ state: ModelAvailability) {
        let current = models[name]
        models[name] = InstalledModel(name: name, folder: current?.folder ?? URL(fileURLWithPath: ""), bytes: current?.bytes ?? 0, state: state)
    }

    private func findModel(named name: String, beneath base: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        return enumerator.compactMap { $0 as? URL }.first { $0.hasDirectoryPath && $0.lastPathComponent.localizedCaseInsensitiveContains(name) && (try? WhisperModelValidator.validate(folder: $0)) != nil }
    }

    private func checkStorage(for name: String, at base: URL) throws {
        let estimate: Int64 = name == "small.en" ? 1_500_000_000 : 600_000_000
        let values = try base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        guard available > estimate else { throw ModelValidationError.insufficientStorage(required: estimate, available: available) }
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0) { $0 + Int64($1) }
    }
}

actor WhisperKitEnginePool: Transcribing {
    private var engines: [String: WhisperKit] = [:]
    private var folders: [String: URL] = [:]
    private let profile: TranscriptionProfile

    init(profile: TranscriptionProfile, modelFolder: URL) {
        self.profile = profile
        folders[profile.model] = modelFolder
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionOutput {
        let totalStart = Date()
        let wasWarm = engines[profile.model] != nil
        let initializationStart = Date()
        let engine: WhisperKit
        if let loaded = engines[profile.model] { engine = loaded }
        else {
            guard let folder = folders[profile.model] else { throw ModelValidationError.incomplete(profile.model) }
            let config = WhisperKitConfig(model: profile.model, modelFolder: folder.path, verbose: false, prewarm: true, load: true, download: false)
            let loaded = try await WhisperKit(config)
            engines[profile.model] = loaded
            engine = loaded
        }
        let initialization = Date().timeIntervalSince(initializationStart)
        try Task.checkCancellation()
        let inferenceStart = Date()
        let input = AudioInputOptions(audioLoadingMode: .incremental(chunkDurationSeconds: 60, maxBufferedChunks: 1))
        let decoding = DecodingOptions(language: "en", temperatureFallbackCount: profile == .fast ? 1 : 5, usePrefillPrompt: true, detectLanguage: false, compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.6)
        let results = try await engine.transcribe(audioPath: request.audioFileURL.path, audioInputOptions: input, decodeOptions: decoding)
        try Task.checkCancellation()
        let inference = Date().timeIntervalSince(inferenceStart)
        let segments = results.flatMap(\.segments).map { TranscriptSegment(start: Double($0.start), end: Double($0.end), text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return TranscriptionOutput(text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines), segments: segments, engine: "WhisperKit 1.1.1", model: profile.model, performance: TranscriptionPerformance(modelInitializationSeconds: initialization, inferenceSeconds: inference, totalSeconds: Date().timeIntervalSince(totalStart), wasWarm: wasWarm))
    }

    func unload() async {
        for engine in engines.values { await engine.unloadModels() }
        engines.removeAll()
    }
}
