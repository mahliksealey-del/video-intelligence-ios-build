import Foundation

enum MediaDownloadError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedScheme
    case serverRejected(Int)
    case unsupportedContent
    case unsafeDestination
    case providerRequiresExtractor(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a complete direct media URL."
        case .unsupportedScheme: return "Only direct HTTP or HTTPS media links are supported."
        case .serverRejected(let code): return "The media server returned HTTP \(code)."
        case .unsupportedContent: return "This link did not return a supported media file. Webpages, protected streams, and DRM media are not supported."
        case .unsafeDestination: return "For your safety, downloads from this local or private-network address are blocked."
        case .providerRequiresExtractor(let provider): return "\(provider) links require an on-device extraction runtime that is not included in this build. Direct media links still work."
        }
    }
}

enum MediaURLValidator {
    static func validate(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else { throw MediaDownloadError.invalidURL }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw MediaDownloadError.unsupportedScheme }
        guard URLSafetyPolicy.isPublic(url) else { throw MediaDownloadError.unsafeDestination }
        return url
    }
}

enum MediaProvider: String, Sendable {
    case youtube = "YouTube"
    case tiktok = "TikTok"
    case instagram = "Instagram"
    case direct = "Direct media"

    static func detect(_ url: URL) -> MediaProvider {
        let host = url.host?.lowercased() ?? ""
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") { return .youtube }
        if host == "tiktok.com" || host.hasSuffix(".tiktok.com") { return .tiktok }
        if host == "instagram.com" || host.hasSuffix(".instagram.com")
            || host == "instagr.am" || host == "www.instagr.am" { return .instagram }
        return .direct
    }
}

enum MediaResolutionRoute: Equatable {
    case direct
    case browser
    case extractor

    case universalBrowser

    static func forURL(_ url: URL) -> MediaResolutionRoute {
        if MediaProvider.detect(url) != .direct { return forProvider(MediaProvider.detect(url)) }
        let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "ogg", "webm", "flac"]
        return mediaExtensions.contains(url.pathExtension.lowercased()) ? .direct : .universalBrowser
    }

    static func forProvider(_ provider: MediaProvider?) -> MediaResolutionRoute {
        switch provider {
        case .direct, .none: return .direct
        case .tiktok: return .browser
        case .youtube, .instagram: return .extractor
        }
    }
}

enum URLSafetyPolicy {
    static func isPublic(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host != "localhost", !host.hasSuffix(".local") else { return false }
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 || parts[0] == 127 || parts[0] == 0 { return false }
            if parts[0] == 169 && parts[1] == 254 { return false }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return false }
            if parts[0] == 192 && parts[1] == 168 { return false }
        }
        return true
    }
}

/// No arbitrary file-size cap. Check *actual available storage* instead.
/// If available space cannot be queried, the OS remains authoritative.
enum DownloadStoragePolicy {
    // Operating-system breathing room; this is NOT a per-file size limit.
    static let systemReserveBytes: Int64 = 512 * 1024 * 1024

    static func availableBytes(on volume: URL = FileManager.default.temporaryDirectory) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: volume.path),
              let free = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    static func allows(available: Int64, remaining: Int64?) -> Bool {
        let usable = available - systemReserveBytes
        guard usable > 0 else { return false }
        guard let remaining, remaining >= 0 else { return true }
        return remaining <= usable
    }

    static func check(remaining: Int64? = nil,
                      on volume: URL = FileManager.default.temporaryDirectory) throws {
        guard let free = availableBytes(on: volume) else { return }
        if !allows(available: free, remaining: remaining) {
            throw DownloadStorageError(available: free, remaining: remaining)
        }
    }
}

struct DownloadStorageError: LocalizedError {
    let available: Int64
    let remaining: Int64?
    var errorDescription: String? {
        let free = ByteCountFormatter.string(fromByteCount: max(0, available), countStyle: .file)
        if let remaining, remaining > 0 {
            let need = ByteCountFormatter.string(fromByteCount: remaining, countStyle: .file)
            return "Not enough free iPhone storage to finish this download (\(need) still needed, \(free) free). Video Intelligence has no fixed file-size limit. Free up space and retry."
        }
        return "iPhone storage is nearly full (\(free) free). Free up space and retry. Video Intelligence has no fixed file-size limit."
    }
}

struct MediaDownloader {

    func download(from url: URL, session: URLSession = .shared) async throws -> URL {
        try DownloadStoragePolicy.check()
        let (temporaryURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse else { throw MediaDownloadError.unsupportedContent }
        guard (200...299).contains(http.statusCode) else { throw MediaDownloadError.serverRejected(http.statusCode) }
        guard let finalURL = response.url, URLSafetyPolicy.isPublic(finalURL) else { throw MediaDownloadError.unsafeDestination }
        // A completed multi-gigabyte download is valid regardless of size.
        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) > 0 else { throw MediaDownloadError.unsupportedContent }
        let suggested = response.suggestedFilename ?? url.lastPathComponent
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((suggested as NSString).pathExtension)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        guard MediaClassifier.classify(destination) != nil, response.mimeType?.hasPrefix("text/") != true else { try? FileManager.default.removeItem(at: destination); throw MediaDownloadError.unsupportedContent }
        return destination
    }
}
