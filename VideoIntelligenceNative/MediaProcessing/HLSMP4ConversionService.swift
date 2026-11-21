import AVFoundation
import Foundation

/// Converts a user-selected HLS VOD *source* into a separate shareable MP4.
/// Apple-managed offline .movpkg packages are never copied, parsed, or changed.
/// TS/H.264+AAC uses a pinned MIT-licensed C remuxer; clear fMP4/CMAF is
/// assembled into an ordinary fragmented MP4 without transcoding.
enum HLSMP4Error: LocalizedError, Equatable {
    case unsafeSource, invalidPlaylist, liveNotSupported, protectedMedia
    case unsupportedFeatures, unsupportedFormat, unreachableSource
    case invalidMP4, conversionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unsafeSource:
            return "This HLS link or one of its resources is not a safe public HTTPS URL."
        case .invalidPlaylist:
            return "The source did not provide a valid HLS playlist."
        case .liveNotSupported:
            return "Only completed HLS videos can be saved as MP4; live streams are unsupported."
        case .protectedMedia:
            return "This stream uses protected media or an unsupported encryption format. DRM cannot be converted."
        case .unsupportedFeatures:
            return "This HLS playlist uses alternate audio, byte ranges or low-latency features that this converter does not support yet."
        case .unsupportedFormat:
            return "This HLS source uses a video/audio format the on-device remuxer cannot handle."
        case .unreachableSource:
            return "The HLS playlist or a video segment was unreachable. It may have expired, require a website session, or be unavailable outside the browser."
        case .invalidMP4:
            return "The conversion output could not be verified as a playable MP4 with a video track. No incomplete file was saved."
        case .conversionFailed(let code):
            return "The HLS transport-stream remuxer could not produce a valid MP4 (code \(code)). Some codecs or segment layouts are unsupported."
        }
    }
}

struct HLSMediaPlan: Equatable, Sendable {
    enum Format: Sendable { case ts, fragmentedMP4 }
    let playlistURL: URL
    let segments: [URL]
    let initialization: URL?
    let format: Format
}

enum HLSPlaylistPlanner {
    enum Result: Equatable {
        case master(URL)
        case media(HLSMediaPlan)
    }

    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty, !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".onion"),
              URLSafetyPolicy.isPublic(url) else {
            throw HLSMP4Error.unsafeSource
        }
    }

    static func resolve(_ value: String, relativeTo base: URL) throws -> URL {
        guard value.count <= 8192, !value.contains("{"),
              let url = URL(string: value, relativeTo: base)?.absoluteURL else {
            throw HLSMP4Error.invalidPlaylist
        }
        try validate(url)
        return url
    }

    static func quotedURI(_ line: String) -> String? {
        guard let begin = line.range(of: "URI=\"")?.upperBound,
              let end = line[begin...].firstIndex(of: "\"") else {
            return nil
        }
        return String(line[begin..<end])
    }

    static func parse(_ source: String, at playlistURL: URL) throws -> Result {
        try validate(playlistURL)
        guard source.utf8.count <= 2 * 1024 * 1024 else {
            throw HLSMP4Error.invalidPlaylist
        }
        let lines = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U" else { throw HLSMP4Error.invalidPlaylist }
        if lines.contains(where: {
            $0.hasPrefix("#EXT-X-SESSION-KEY") || $0.hasPrefix("#EXT-X-PART:") ||
            $0.hasPrefix("#EXT-X-PRELOAD-HINT") || $0.hasPrefix("#EXT-X-SKIP:")
        }) { throw HLSMP4Error.unsupportedFeatures }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            // Do not quietly export a video-only rendition if the master
            // advertises separate AUDIO tracks. No hidden track loss.
            if lines.contains(where: { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }) {
                throw HLSMP4Error.unsupportedFeatures
            }
            var choices: [(bandwidth: Int, url: URL)] = []
            for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
                guard index + 1 < lines.count else { throw HLSMP4Error.invalidPlaylist }
                let attributes = lines[index]
                if attributes.contains("AUDIO=") { throw HLSMP4Error.unsupportedFeatures }
                guard !lines[index + 1].hasPrefix("#") else {
                    throw HLSMP4Error.invalidPlaylist
                }
                let bandwidth: Int = {
                    guard let range = attributes.range(of: "BANDWIDTH=") else { return 0 }
                    let value = attributes[range.upperBound...]
                    return Int(value.prefix(while: { $0.isNumber })) ?? 0
                }()
                choices.append((bandwidth,
                                try resolve(lines[index + 1], relativeTo: playlistURL)))
            }
            guard let choice = choices.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw HLSMP4Error.invalidPlaylist
            }
            return .master(choice.url)
        }

        guard lines.contains("#EXT-X-ENDLIST") else { throw HLSMP4Error.liveNotSupported }
        if lines.contains(where: {
            $0.hasPrefix("#EXT-X-BYTERANGE") ||
            $0.hasPrefix("#EXT-X-DISCONTINUITY") ||
            $0.hasPrefix("#EXT-X-I-FRAMES-ONLY")
        }) { throw HLSMP4Error.unsupportedFeatures }

        var map: URL?
        var hasAes128 = false
        var segments: [URL] = []
        for line in lines {
            if line.hasPrefix("#EXT-X-MAP:") {
                guard let value = quotedURI(line) else { throw HLSMP4Error.invalidPlaylist }
                map = try resolve(value, relativeTo: playlistURL)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                if line.contains("METHOD=NONE") { continue }
                if line.contains("METHOD=AES-128"),
                   !line.contains("KEYFORMAT=") || line.contains("KEYFORMAT=\"identity\"") {
                    guard let value = quotedURI(line) else {
                        throw HLSMP4Error.invalidPlaylist
                    }
                    _ = try resolve(value, relativeTo: playlistURL)
                    hasAes128 = true
                } else {
                    throw HLSMP4Error.protectedMedia
                }
            } else if !line.hasPrefix("#"), !line.isEmpty {
                guard segments.count < 10_000 else {
                    throw HLSMP4Error.unsupportedFeatures
                }
                segments.append(try resolve(line, relativeTo: playlistURL))
            }
        }
        guard !segments.isEmpty else { throw HLSMP4Error.invalidPlaylist }
        if map != nil && hasAes128 { throw HLSMP4Error.protectedMedia }
        return .media(HLSMediaPlan(
            playlistURL: playlistURL, segments: segments, initialization: map,
            format: map == nil ? .ts : .fragmentedMP4))
    }
}

private final class HLSDownloadRedirectGuard: NSObject, URLSessionTaskDelegate,
                                               @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, (try? HLSPlaylistPlanner.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private final class HLSConversionProgressBox: @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }
}

struct HLSMP4ConversionService {
    static func isSupportedSource(_ candidate: UniversalWebMediaCandidate) -> Bool {
        candidate.kind == .hls &&
        candidate.url.path.lowercased().hasSuffix(".m3u8") &&
        (try? HLSPlaylistPlanner.validate(candidate.url)) != nil
    }

    func convert(_ candidate: UniversalWebMediaCandidate,
                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard Self.isSupportedSource(candidate) else { throw HLSMP4Error.unsafeSource }
        try DownloadStoragePolicy.check()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 45
        cfg.HTTPCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg, delegate: HLSDownloadRedirectGuard(),
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var current = candidate.url
        var selectedPlan: HLSMediaPlan?
        for _ in 0..<3 {
            let playlist = try await fetchPlaylist(current, candidate: candidate,
                                                   session: session)
            switch try HLSPlaylistPlanner.parse(playlist, at: current) {
            case .master(let next):
                current = next
            case .media(let plan):
                selectedPlan = plan
            }
            if selectedPlan != nil { break }
        }
        guard let plan = selectedPlan else { throw HLSMP4Error.invalidPlaylist }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("VI-HLSMP4-" + UUID().uuidString)
            .appendingPathExtension("mp4")
        do {
            switch plan.format {
            case .ts:
                try await convertTransportStream(plan, destination: destination,
                                                 candidate: candidate, progress: progress)
            case .fragmentedMP4:
                try await writeFragmentedMP4(plan, destination: destination,
                                             candidate: candidate, session: session,
                                             progress: progress)
            }
            try Task.checkCancellation()
            let asset = AVURLAsset(url: destination)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard !video.isEmpty,
                  FileManager.default.fileExists(atPath: destination.path),
                  ((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            else { throw HLSMP4Error.invalidMP4 }
            progress(1)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func originReferer(_ page: URL) -> String {
        guard page.scheme?.lowercased() == "https", let host = page.host,
              URLSafetyPolicy.isPublic(page) else { return "" }
        return "https://" + host + "/"
    }

    private func fetchPlaylist(_ url: URL, candidate: UniversalWebMediaCandidate,
                               session: URLSession) async throws -> String {
        try HLSPlaylistPlanner.validate(url)
        var request = URLRequest(url: url)
        if let agent = candidate.userAgent, agent.count < 512,
           !agent.contains("\n"), !agent.contains("\r") {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue(originReferer(candidate.pageURL), forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let actual = response.url,
              (try? HLSPlaylistPlanner.validate(actual)) != nil,
              data.count <= 2 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else {
            throw HLSMP4Error.unreachableSource
        }
        return text
    }

    private func writeFragmentedMP4(_ plan: HLSMediaPlan, destination: URL,
                                    candidate: UniversalWebMediaCandidate,
                                    session: URLSession,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let initialization = plan.initialization else {
            throw HLSMP4Error.unsupportedFormat
        }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw HLSMP4Error.invalidMP4
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let resources = [initialization] + plan.segments
        for (index, url) in resources.enumerated() {
            try Task.checkCancellation()
            try DownloadStoragePolicy.check()
            var request = URLRequest(url: url)
            request.setValue(originReferer(candidate.pageURL), forHTTPHeaderField: "Referer")
            if let agent = candidate.userAgent, agent.count < 512,
               !agent.contains("\n"), !agent.contains("\r") {
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let actual = response.url,
                  (try? HLSPlaylistPlanner.validate(actual)) != nil else {
                throw HLSMP4Error.unreachableSource
            }
            let input = try FileHandle(forReadingFrom: temporary)
            defer { try? input.close() }
            var wroteBytes = false
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                wroteBytes = true
                try output.write(contentsOf: chunk)
            }
            if !wroteBytes { throw HLSMP4Error.invalidMP4 }
            progress(min(0.99, Double(index + 1) / Double(resources.count)))
        }
    }

    private func convertTransportStream(_ plan: HLSMediaPlan, destination: URL,
                                        candidate: UniversalWebMediaCandidate,
                                        progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let token = hls_remux_cancel_token_create() else {
            throw HLSMP4Error.conversionFailed(-6)
        }
        defer { hls_remux_cancel_token_free(token) }
        let box = HLSConversionProgressBox(progress)
        let retained = Unmanaged.passRetained(box)
        defer { retained.release() }
        let callback: hls2mp4_progress_cb = { done, total, context in
            guard let context, total > 0 else { return }
            let report = Unmanaged<HLSConversionProgressBox>
                .fromOpaque(context).takeUnretainedValue()
            report.report(min(0.99, max(0, Double(done) / Double(total))))
        }
        let playlist = plan.playlistURL.absoluteString
        let output = destination.path
        let referer = originReferer(candidate.pageURL)
        let agent = candidate.userAgent ?? ""
        let result = try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return playlist.withCString { inputPointer in
                    output.withCString { outputPointer in
                        referer.withCString { refererPointer in
                            agent.withCString { agentPointer in
                                hls_remux_http_set_request_headers(refererPointer, agentPointer)
                                defer { hls_remux_http_set_request_headers(nil, nil) }
                                var opts = hls2mp4_options()
                                opts.input_url = inputPointer
                                opts.output_path = outputPointer
                                opts.on_progress = callback
                                opts.on_log = nil
                                opts.userdata = retained.toOpaque()
                                opts.timeout_ms = 30_000
                                opts.max_retries = 2
                                opts.cancel_token = token
                                return hls2mp4_convert(&opts)
                            }
                        }
                    }
                }
            }.value
        }, onCancel: {
            hls_remux_cancel_token_request(token)
        })
        if Task.isCancelled || result == HLS2MP4_ERR_CANCELED.rawValue {
            throw CancellationError()
        }
        guard result == HLS2MP4_OK.rawValue else {
            throw HLSMP4Error.conversionFailed(result)
        }
    }
}
