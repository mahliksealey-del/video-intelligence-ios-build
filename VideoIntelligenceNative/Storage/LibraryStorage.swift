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

    // Apple's AVAssetDownloadURLSession owns the offline .movpkg location.
    // Store a persistent reference in the library index, never a copied package.
    private static let offlineHLSPrefix = "hlsasset:"

    func registerOfflineHLSAsset(at sourceURL: URL) throws -> String {
        let location = sourceURL.standardizedFileURL
        guard sourceURL.isFileURL,
              location.pathExtension.lowercased() == "movpkg",
              fileManager.fileExists(atPath: location.path) else {
            throw StorageError.invalidRelativePath
        }
        return Self.offlineHLSPrefix + Data(location.absoluteString.utf8).base64EncodedString()
    }

    func URLFor(relativePath: String) throws -> URL {
        if relativePath.hasPrefix(Self.offlineHLSPrefix) {
            let value = String(relativePath.dropFirst(Self.offlineHLSPrefix.count))
            guard let decoded = Data(base64Encoded: value),
                  let string = String(data: decoded, encoding: .utf8),
                  let location = URL(string: string),
                  location.isFileURL,
                  location.pathExtension.lowercased() == "movpkg",
                  fileManager.fileExists(atPath: location.path) else {
                throw StorageError.invalidRelativePath
            }
            return location
        }
        guard !relativePath.contains(".."), !relativePath.hasPrefix("/") else { throw StorageError.invalidRelativePath }
        return documentsURL.appendingPathComponent(relativePath)
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
        if fileManager.fileExists(atPath: cachesURL.path) { try fileManager.removeItem(at: cachesURL) }
        try fileManager.createDirectory(at: cachesURL, withIntermediateDirectories: true)
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
