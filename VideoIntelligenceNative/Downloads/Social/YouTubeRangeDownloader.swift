import Foundation

/// Distinguishes video-server access failures from a missing iPhone codec.
/// No URL signatures, cookies, or authentication tokens appear in the message.
struct YouTubeStreamAccessError: LocalizedError, Equatable {
    let statusCode: Int

    var errorDescription: String? {
        switch statusCode {
        case 401, 403:
            return "YouTube's video server rejected the extracted stream (HTTP \(statusCode)). This can happen when a signed URL expires, the selected player client is blocked, or a playback token is unavailable. Try resolving the video again or selecting a different available format."
        case 429:
            return "YouTube's video server is rate-limiting the download (HTTP 429). Avoid repeated retries and try again later."
        default:
            return "YouTube's video server returned HTTP \(statusCode) instead of the requested media."
        }
    }

    static func isYouTubeMediaHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }
}

/// yt-dlp's YouTube formats can specify downloader_options.http_chunk_size.
/// Honor that instruction for googlevideo.com media only. Other providers keep
/// the existing URLSession download path and cookies/session behavior unchanged.
/// A response ignoring Range is accepted as one full validated download.
struct YouTubeRangeDownloader {
    static func shouldUse(_ track: SocialMediaTrack) -> Bool {
        guard let size = track.chunkSize, size > 0,
              let host = track.url.host?.lowercased() else { return false }
        return host == "googlevideo.com" || host.hasSuffix(".googlevideo.com")
    }

    static func byteRange(start: Int64, chunkSize: Int, total: Int64?) -> String {
        let count = max(1, min(Int64(chunkSize), 10_485_760))
        // Saturating Int64 arithmetic without any arbitrary file-size limit.
        var end = start > Int64.max - count ? Int64.max - 1 : start + count - 1
        if let total { end = min(end, total - 1) }
        return "bytes=\(start)-\(end)"
    }

    static func contentRange(_ value: String?) -> (start: Int64, end: Int64, total: Int64)? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasPrefix("bytes ") else { return nil }
        let fields = normalized.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let total = Int64(fields[1]),
              total > 0 else { return nil }
        let positions = fields[0].split(separator: "-", omittingEmptySubsequences: false)
        guard positions.count == 2,
              let start = Int64(positions[0]),
              let end = Int64(positions[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }

    func download(_ track: SocialMediaTrack,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard Self.shouldUse(track), let chunkSize = track.chunkSize else {
            throw SocialExtractionError.unsupported("A ranged download was requested for an unsupported media URL.")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let allowedExtension = ["mp4", "m4a", "mov"].contains(track.fileExtension.lowercased())
            ? track.fileExtension.lowercased() : "mp4"
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(allowedExtension)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var offset: Int64 = 0
        var expectedTotal: Int64?
        // Continue until the actual response's advertised total is complete.
        // Storage availability, not a chunk counter or byte cap, is the limit.
        while true {
            try Task.checkCancellation()
            let remaining = expectedTotal.map { max(0, $0 - offset) }
            try DownloadStoragePolicy.check(remaining: remaining)
            var request = URLRequest(url: track.url)
            track.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue(Self.byteRange(start: offset, chunkSize: chunkSize, total: expectedTotal),
                             forHTTPHeaderField: "Range")
            let (piece, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: piece) }

            guard let http = response as? HTTPURLResponse,
                  let finalURL = response.url,
                  URLSafetyPolicy.isPublic(finalURL),
                  ["https", "http"].contains(finalURL.scheme?.lowercased() ?? "") else {
                throw MediaDownloadError.unsafeDestination
            }
            let mime = (http.mimeType ?? "").lowercased()
            guard !mime.hasPrefix("text/"), !mime.contains("json") else {
                throw MediaDownloadError.unsupportedContent
            }
            let byteCount = Int64((try piece.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard byteCount > 0 else { throw MediaDownloadError.unsupportedContent }

            // Some media hosts ignore Range requests and return the full file.
            // Only accept this at offset zero; never append duplicate data.
            if http.statusCode == 200 && offset == 0 {
                try handle.close()
                try FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: piece, to: output)
                completed = true
                progress(1)
                return output
            }

            if [401, 403, 429].contains(http.statusCode) {
                throw YouTubeStreamAccessError(statusCode: http.statusCode)
            }
            guard http.statusCode == 206,
                  let range = Self.contentRange(http.value(forHTTPHeaderField: "Content-Range")),
                  range.start == offset,
                  range.end - range.start + 1 == byteCount,
                  expectedTotal == nil || expectedTotal == range.total else {
                throw SocialExtractionError.unsupported(
                    "The YouTube media server returned an invalid ranged response (HTTP \(http.statusCode))."
                )
            }
            expectedTotal = range.total
            try DownloadStoragePolicy.check(remaining: range.total - offset)

            let source = try FileHandle(forReadingFrom: piece)
            defer { try? source.close() }
            var copied: Int64 = 0
            while let bytes = try source.read(upToCount: 256 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                try handle.write(contentsOf: bytes)
                copied += Int64(bytes.count)
            }
            guard copied == byteCount else { throw MediaDownloadError.unsupportedContent }
            offset = range.end + 1
            progress(min(1, Double(offset) / Double(range.total)))
            if offset == range.total {
                completed = true
                return output
            }
        }
    }
}
