import Foundation

enum StorageError: LocalizedError {
    case invalidRelativePath

    var errorDescription: String? { "The stored media path is invalid." }
}

actor LibraryStorage {
    private let fileManager: FileManager
    nonisolated let documentsURL: URL
    nonisolated let applicationSupportURL: URL
    nonisolated let cachesURL: URL

    private var indexURL: URL { applicationSupportURL.appendingPathComponent("library-index.json") }

    init(fileManager: FileManager = .default, documentsURL: URL? = nil, applicationSupportURL: URL? = nil, cachesURL: URL? = nil) {
        self.fileManager = fileManager
        self.documentsURL = documentsURL ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.applicationSupportURL = applicationSupportURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.cachesURL = cachesURL ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    func prepareDirectories() throws {
        for name in ["Videos", "Audio", "Transcripts", "Exports"] {
            try fileManager.createDirectory(at: documentsURL.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var modelURL = modelDirectory
        try? modelURL.setResourceValues(values)
    }

    var modelDirectory: URL { applicationSupportURL.appendingPathComponent("WhisperModels", isDirectory: true) }

    func loadIndex() throws -> MediaLibraryIndex {
        guard fileManager.fileExists(atPath: indexURL.path) else { return MediaLibraryIndex() }
        return try JSONDecoder.library.decode(MediaLibraryIndex.self, from: Data(contentsOf: indexURL))
    }

    func saveIndex(_ index: MediaLibraryIndex) throws {
        try prepareDirectories()
        let data = try JSONEncoder.library.encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    func importMedia(from sourceURL: URL, kind: MediaKind, id: UUID) throws -> String {
        try prepareDirectories()
        let folder = kind == .video ? "Videos" : "Audio"
        let preferredName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.lowercased()
        let filename = uniqueFilename(preferredName: preferredName, extension: ext, folder: folder, id: id)
        let destination = documentsURL.appendingPathComponent(folder).appendingPathComponent(filename)
        try SecurityScopedAccess.withAccess(to: sourceURL) {
            try fileManager.copyItem(at: sourceURL, to: destination)
        }
        return "\(folder)/\(filename)"
    }

    // The offline .movpkg remains at Apple's selected location. An old
    // version saved its absolute file:// URL, which breaks after iOS changes
    // the app-container UUID during an update (Apple TN2285).
    // NEW records store a relative reference to the CURRENT app container.
    // Do not copy/move system-managed HLS packages or delete missing entries.
    private static let offlineHLSPrefix = "hlsasset:" // legacy absolute URL
    private static let offlineHLSRelativePrefix = "hlsrel:" // current portable form

    private var containerURL: URL {
        documentsURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func isSafeOfflineRelativePath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts.first == "Library" || parts.first == "Documents",
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !value.contains("\\"),
              value.lowercased().hasSuffix(".movpkg") else { return false }
        return true
    }

    private func pathWithinContainer(_ location: URL) -> String? {
        guard location.isFileURL else { return nil }
        let root = containerURL.path
        let path = location.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        let relative = String(path.dropFirst(root.count + 1))
        return Self.isSafeOfflineRelativePath(relative) ? relative : nil
    }

    /// The old absolute path might reference the former container UUID.
    /// Reconstruct the original *relative* location only; never search for
    /// a different asset with the same filename or modify the old file.
    private static func legacyContainerRelativePath(_ location: URL) -> String? {
        guard location.isFileURL else { return nil }
        let segments = location.standardizedFileURL.pathComponents
        guard let index = segments.indices.first(where: { i in
            i + 3 < segments.count &&
            segments[i] == "Containers" &&
            segments[i + 1] == "Data" &&
            segments[i + 2] == "Application" &&
            UUID(uuidString: segments[i + 3]) != nil
        }) else { return nil }
        let start = index + 4
        guard start < segments.count else { return nil }
        let relative = segments[start...].joined(separator: "/")
        return isSafeOfflineRelativePath(relative) ? relative : nil
    }

    private static func reference(forRelative relative: String) -> String {
        offlineHLSRelativePrefix + Data(relative.utf8).base64EncodedString()
    }

    private static func decodedReference(_ reference: String, prefix: String) -> String? {
        guard reference.hasPrefix(prefix) else { return nil }
        let encoded = String(reference.dropFirst(prefix.count))
        guard let bytes = Data(base64Encoded: encoded),
              let string = String(data: bytes, encoding: .utf8) else { return nil }
        return string
    }

    func registerOfflineHLSAsset(at sourceURL: URL) throws -> String {
        let location = sourceURL.standardizedFileURL
        guard sourceURL.isFileURL,
              location.pathExtension.lowercased() == "movpkg",
              fileManager.fileExists(atPath: location.path) else {
            throw StorageError.invalidRelativePath
        }
        if let relative = pathWithinContainer(location) {
            return Self.reference(forRelative: relative)
        }
        // External system-managed locations cannot safely be rebased to the
        // app container. Preserve original Apple URL when outside that scope.
        return Self.offlineHLSPrefix +
            Data(location.absoluteString.utf8).base64EncodedString()
    }

    func URLFor(relativePath: String) throws -> URL {
        if relativePath.hasPrefix(Self.offlineHLSRelativePrefix) {
            guard let relative = Self.decodedReference(
                relativePath, prefix: Self.offlineHLSRelativePrefix),
                  Self.isSafeOfflineRelativePath(relative) else {
                throw StorageError.invalidRelativePath
            }
            let current = containerURL.appendingPathComponent(relative)
                .standardizedFileURL
            guard fileManager.fileExists(atPath: current.path) else {
                throw StorageError.invalidRelativePath
            }
            return current
        }
        if relativePath.hasPrefix(Self.offlineHLSPrefix) {
            guard let string = Self.decodedReference(
                relativePath, prefix: Self.offlineHLSPrefix),
                  let old = URL(string: string),
                  old.isFileURL,
                  old.pathExtension.lowercased() == "movpkg" else {
                throw StorageError.invalidRelativePath
            }
            if fileManager.fileExists(atPath: old.path) { return old }
            // An app update can rehome files into a new UUID container while
            // preserving the Library-relative path. Recover that exact path.
            if let relative = Self.legacyContainerRelativePath(old) {
                let current = containerURL.appendingPathComponent(relative)
                    .standardizedFileURL
                if fileManager.fileExists(atPath: current.path) {
                    return current
                }
            }
            throw StorageError.invalidRelativePath
        }
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else {
            throw StorageError.invalidRelativePath
        }
        return documentsURL.appendingPathComponent(relativePath)
    }

    /// Recover only proven, still-present packages. Unresolved records remain
    /// unchanged so a future update or manual backup may still recover them.
    func repairOfflineHLSReferences(_ originals: [MediaLibraryItem])
        -> (items: [MediaLibraryItem], repaired: Int, unresolved: Int) {
        var repaired = 0
        var unresolved = 0
        var result = originals
        for i in result.indices {
            guard let original = result[i].mediaRelativePath,
                  original.hasPrefix(Self.offlineHLSPrefix) else { continue }
            guard let resolved = try? URLFor(relativePath: original) else {
                unresolved += 1
                continue
            }
            guard let relative = pathWithinContainer(resolved) else {
                // Apple's asset remains outside our sandbox. Its original
                // reference remains valid and should not be overwritten.
                continue
            }
            result[i].mediaRelativePath = Self.reference(forRelative: relative)
            repaired += 1
        }
        return (result, repaired, unresolved)
    }

    func writeTranscript(_ transcript: TranscriptRecord, id: UUID) throws -> String {
        try prepareDirectories()
        let relative = "Transcripts/\(id.uuidString.lowercased()).json"
        let url = try URLFor(relativePath: relative)
        try JSONEncoder.transcript.encode(transcript).write(to: url, options: .atomic)
        return relative
    }

    func loadTranscript(relativePath: String) throws -> TranscriptRecord {
        try JSONDecoder.transcript.decode(TranscriptRecord.self, from: Data(contentsOf: URLFor(relativePath: relativePath)))
    }

    func deleteMedia(for item: MediaLibraryItem) throws {
        if let path = item.mediaRelativePath { try? fileManager.removeItem(at: URLFor(relativePath: path)) }
        if let path = item.audioRelativePath, path != item.mediaRelativePath { try? fileManager.removeItem(at: URLFor(relativePath: path)) }
    }

    func deleteItemFiles(for item: MediaLibraryItem) throws {
        try deleteMedia(for: item)
        if let path = item.transcriptRelativePath { try? fileManager.removeItem(at: URLFor(relativePath: path)) }
    }

    func clearCaches() throws {
        // NEVER remove Library/Caches wholesale. Apple may store offline
        // AVAssetDownloadURLSession .movpkg video packages anywhere inside
        // its system-managed cache tree; those are user media, not disposable.
        // Only delete the app's explicitly owned regenerable preview folder.
        let owned = cachesURL.appendingPathComponent(
            "VideoIntelligenceRegenerable", isDirectory: true)
        if fileManager.fileExists(atPath: owned.path) {
            try fileManager.removeItem(at: owned)
        }
        try fileManager.createDirectory(at: owned, withIntermediateDirectories: true)
    }

    func storageUsage() -> Int64 {
        [documentsURL, applicationSupportURL, cachesURL].reduce(0) { $0 + directorySize($1) }
    }

    private func uniqueFilename(preferredName: String, extension ext: String, folder: String, id: UUID) -> String {
        let safe = preferredName.replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "-", options: .regularExpression)
        let base = safe.isEmpty ? "media" : safe
        let suffix = String(id.uuidString.lowercased().prefix(8))
        return ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } }.reduce(0) { $0 + Int64($1) }
    }
}

extension JSONEncoder {
    static var library: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
    static var transcript: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }
}

extension JSONDecoder {
    static var library: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static var transcript: JSONDecoder { JSONDecoder() }
}
