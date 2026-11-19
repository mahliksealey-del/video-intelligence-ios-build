import Foundation

enum MediaDownloadError: LocalizedError, Equatable {
    case invalidURL
    case unsupportedScheme
    case serverRejected(Int)
    case unsupportedContent

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a complete direct media URL."
        case .unsupportedScheme: return "Only direct HTTP or HTTPS media links are supported."
        case .serverRejected(let code): return "The media server returned HTTP \(code)."
        case .unsupportedContent: return "This link did not return a supported media file. Webpages, protected streams, and DRM media are not supported."
        }
    }
}

enum MediaURLValidator {
    static func validate(_ value: String) throws -> URL {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), url.host != nil else { throw MediaDownloadError.invalidURL }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw MediaDownloadError.unsupportedScheme }
        return url
    }
}

struct MediaDownloader {
    func download(from url: URL, session: URLSession = .shared) async throws -> URL {
        let (temporaryURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse else { throw MediaDownloadError.unsupportedContent }
        guard (200...299).contains(http.statusCode) else { throw MediaDownloadError.serverRejected(http.statusCode) }
        let suggested = response.suggestedFilename ?? url.lastPathComponent
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension((suggested as NSString).pathExtension)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        guard MediaClassifier.classify(destination) != nil else { try? FileManager.default.removeItem(at: destination); throw MediaDownloadError.unsupportedContent }
        return destination
    }
}
