import AVFoundation
import Foundation

/// Converts a user-selected HLS VOD *source* into a separate shareable MP4.
/// Apple-managed offline .movpkg packages are never copied, parsed, or changed.
/// TS/H.264+AAC uses a pinned MIT-licensed C remuxer; clear fMP4/CMAF is
/// assembled into an ordinary fragmented MP4 without transcoding.
enum HLSMP4Error: LocalizedError, Equatable {
    case unsafeSource, invalidPlaylist, liveNotSupported, protectedMedia
    case unsupportedFeatures, unsupportedFormat, unreachableSource
    case specificUnsupported(String)
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
            return "This HLS playlist uses a format or timeline feature this converter cannot safely process."
        case .specificUnsupported(let detail):
            return "Unsupported HLS feature: \(detail). No original media was changed."
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

struct HLSByteRange: Equatable, Sendable {
    let length: Int64
    let offset: Int64

    var lastByte: Int64 { offset + length - 1 }

    static func parse(_ text: String, implicitOffset: Int64? = nil) throws -> HLSByteRange {
        let numbers = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(numbers.count),
              let count = Int64(numbers[0]), (1...67_108_864).contains(count),
              let offset = numbers.count == 2 ? Int64(numbers[1]) : implicitOffset,
              offset >= 0, offset <= Int64.max - count else {
            throw HLSMP4Error.invalidPlaylist
        }
        return HLSByteRange(length: count, offset: offset)
    }
}

struct HLSMediaPlan: Equatable, Sendable {
    enum Format: Sendable { case ts, fragmentedMP4 }
    let playlistURL: URL
    let segments: [URL]
    let ranges: [HLSByteRange?]
    let initialization: URL?
    let initializationRange: HLSByteRange?
    let format: Format
}

struct HLSMasterSelection: Equatable {
    let variantURL: URL
    let alternateAudioURL: URL?
    let expectsAudio: Bool
}

enum HLSPlaylistPlanner {
    enum Result: Equatable {
        case master(HLSMasterSelection)
        case media(HLSMediaPlan)
    }

    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty, !host.hasSuffix(".localhost"),
              !host.hasSuffix(".internal"), !host.hasSuffix(".onion"),
              !host.contains(":"),
              !(host.split(separator: ".").count == 4 &&
                host.split(separator: ".").allSatisfy { Int($0) != nil }),
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

    /// HLS attribute lists contain quoted commas (e.g. CODECS="avc1,mp4a").
    /// Only split on commas outside double quotes.
    static func attribute(_ line: String, name: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var parts: [String] = []
        var current = ""
        var quoted = false
        for c in line[line.index(after: colon)...] {
            if c == "\"" { quoted.toggle() }
            if c == "," && !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        guard !quoted else { return nil }
        parts.append(current)
        for part in parts {
            let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = name + "="
            if value.hasPrefix(prefix) {
                let raw = String(value.dropFirst(prefix.count))
                if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
                    return String(raw.dropFirst().dropLast())
                }
                return raw
            }
        }
        return nil
    }

    static func quotedURI(_ line: String) -> String? { attribute(line, name: "URI") }

    static func parse(_ source: String, at playlistURL: URL) throws -> Result {
        try validate(playlistURL)
        guard source.utf8.count <= 2 * 1024 * 1024 else {
            throw HLSMP4Error.invalidPlaylist
        }
        let lines = source.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "#EXTM3U" else { throw HLSMP4Error.invalidPlaylist }
        // LL-HLS partial segments may accompany complete VOD segments. Ignore
        // partial hints only when a complete ENDLIST exists. Delta updates,
        // session encryption and incomplete live playlists are not supported.
        if lines.contains(where: { $0.hasPrefix("#EXT-X-SESSION-KEY") }) {
            throw HLSMP4Error.protectedMedia
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-SKIP:") }) {
            throw HLSMP4Error.specificUnsupported("delta-playlist updates")
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-I-FRAMES-ONLY") }) {
            throw HLSMP4Error.specificUnsupported("I-frame-only trick-play rendition")
        }

        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) {
            struct AudioOption {
                let group: String
                let url: URL?
                let isDefault: Bool
            }
            var audio: [AudioOption] = []
            for line in lines where line.hasPrefix("#EXT-X-MEDIA:") &&
                                    attribute(line, name: "TYPE") == "AUDIO" {
                guard let group = attribute(line, name: "GROUP-ID"), !group.isEmpty else {
                    throw HLSMP4Error.invalidPlaylist
                }
                // URI omitted = audio included in video variant (RFC 8216).
                let url = try attribute(line, name: "URI").map {
                    try resolve($0, relativeTo: playlistURL)
                }
                audio.append(AudioOption(group: group, url: url,
                                         isDefault: attribute(line, name: "DEFAULT") == "YES"))
            }

            var choices: [(bandwidth: Int, selection: HLSMasterSelection)] = []
            for index in lines.indices where lines[index].hasPrefix("#EXT-X-STREAM-INF:") {
                guard index + 1 < lines.count,
                      !lines[index + 1].hasPrefix("#") else {
                    throw HLSMP4Error.invalidPlaylist
                }
                let attributes = lines[index]
                let bandwidth = Int(attribute(attributes, name: "BANDWIDTH") ?? "") ?? 0
                let videoURL = try resolve(lines[index + 1], relativeTo: playlistURL)
                var selectedAudio: URL?
                if let group = attribute(attributes, name: "AUDIO") {
                    let options = audio.filter { $0.group == group }
                    guard !options.isEmpty else { throw HLSMP4Error.invalidPlaylist }
                    // Prefer explicitly marked default rendition; only one
                    // alternate track is exported (never silently drop audio).
                    selectedAudio = (options.first(where: \.isDefault) ?? options[0]).url
                }
                choices.append((bandwidth, HLSMasterSelection(
                    variantURL: videoURL, alternateAudioURL: selectedAudio,
                    expectsAudio: attribute(attributes, name: "AUDIO") != nil)))
            }
            guard let best = choices.max(by: { $0.bandwidth < $1.bandwidth }) else {
                throw HLSMP4Error.invalidPlaylist
            }
            return .master(best.selection)
        }

        guard lines.contains("#EXT-X-ENDLIST") else { throw HLSMP4Error.liveNotSupported }
        if lines.contains("#EXT-X-DISCONTINUITY") {
            throw HLSMP4Error.specificUnsupported("media timeline discontinuities")
        }

        var map: URL?
        var mapRange: HLSByteRange?
        var hasAes128 = false
        var segments: [URL] = []
        var ranges: [HLSByteRange?] = []
        var pendingRange: String?
        var previousURL: URL?
        var previousRange: HLSByteRange?
        for line in lines {
            if line.hasPrefix("#EXT-X-MAP:") {
                guard let value = quotedURI(line) else { throw HLSMP4Error.invalidPlaylist }
                map = try resolve(value, relativeTo: playlistURL)
                if let encoded = attribute(line, name: "BYTERANGE") {
                    mapRange = try HLSByteRange.parse(encoded, implicitOffset: 0)
                } else {
                    mapRange = nil
                }
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                guard pendingRange == nil else { throw HLSMP4Error.invalidPlaylist }
                pendingRange = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                if attribute(line, name: "METHOD") == "NONE" {
                    // Keep evidence of any *earlier* encrypted segments.
                } else if attribute(line, name: "METHOD") == "AES-128",
                          (attribute(line, name: "KEYFORMAT") ?? "identity") == "identity" {
                    guard let value = quotedURI(line) else {
                        throw HLSMP4Error.invalidPlaylist
                    }
                    _ = try resolve(value, relativeTo: playlistURL)
                    hasAes128 = true
                } else {
                    throw HLSMP4Error.protectedMedia
                }
            } else if !line.hasPrefix("#") && !line.isEmpty {
                guard segments.count < 10_000 else { throw HLSMP4Error.unsupportedFeatures }
                let url = try resolve(line, relativeTo: playlistURL)
                var range: HLSByteRange?
                if let encoded = pendingRange {
                    let nextOffset: Int64? = (previousURL == url && previousRange != nil)
                        ? previousRange!.offset + previousRange!.length : nil
                    range = try HLSByteRange.parse(encoded, implicitOffset: nextOffset)
                }
                segments.append(url)
                ranges.append(range)
                previousURL = url
                previousRange = range
                pendingRange = nil
            }
        }
        guard !segments.isEmpty, pendingRange == nil else {
            throw HLSMP4Error.invalidPlaylist
        }
        if map != nil && hasAes128 { throw HLSMP4Error.protectedMedia }
        return .media(HLSMediaPlan(
            playlistURL: playlistURL, segments: segments, ranges: ranges,
            initialization: map, initializationRange: mapRange,
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
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg, delegate: HLSDownloadRedirectGuard(),
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var current = candidate.url
        var selectedPlan: HLSMediaPlan?
        var alternateAudioURL: URL?
        var expectsAudio = false
        for _ in 0..<3 {
            let (playlist, finalURL) = try await fetchPlaylist(
                current, candidate: candidate, session: session)
            switch try HLSPlaylistPlanner.parse(playlist, at: finalURL) {
            case .master(let selection):
                current = selection.variantURL
                expectsAudio = expectsAudio || selection.expectsAudio
                if let audio = selection.alternateAudioURL {
                    alternateAudioURL = audio
                }
            case .media(let plan):
                selectedPlan = plan
            }
            if selectedPlan != nil { break }
        }
        guard let plan = selectedPlan else { throw HLSMP4Error.invalidPlaylist }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("VI-HLSMP4-" + UUID().uuidString)
            .appendingPathExtension("mp4")
        let separateVideo = alternateAudioURL != nil
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent("VI-HLSVideo-" + UUID().uuidString)
                .appendingPathExtension("mp4") : destination
        let separateAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("VI-HLSAudio-" + UUID().uuidString)
            .appendingPathExtension("mp4")
        defer {
            if alternateAudioURL != nil {
                try? FileManager.default.removeItem(at: separateVideo)
                try? FileManager.default.removeItem(at: separateAudio)
            }
        }
        do {
            let videoWeight = alternateAudioURL == nil ? 0.99 : 0.65
            try await assemble(plan, at: separateVideo, candidate: candidate,
                               session: session) { fraction in
                progress(min(videoWeight, fraction * videoWeight))
            }
            if let audioURL = alternateAudioURL {
                let (audioText, actualAudioURL) = try await fetchPlaylist(
                    audioURL, candidate: candidate, session: session)
                guard case .media(let audioPlan) = try HLSPlaylistPlanner.parse(
                    audioText, at: actualAudioURL) else {
                    throw HLSMP4Error.unsupportedFeatures
                }
                try await assemble(audioPlan, at: separateAudio, candidate: candidate,
                                   session: session) { fraction in
                    progress(min(0.90, 0.65 + fraction * 0.25))
                }
                let audioAsset = AVURLAsset(url: separateAudio)
                guard !(try await audioAsset.loadTracks(withMediaType: .audio)).isEmpty else {
                    throw HLSMP4Error.unsupportedFormat
                }
                try Task.checkCancellation()
                // Same non-reencoding AVFoundation composition already used
                // by the working adaptive-video downloader. Only the newly
                // assembled copies are composed; no offline movpkg is read.
                try await SocialMediaMerger().merge(
                    video: separateVideo, audio: separateAudio, output: destination)
                progress(0.96)
            }
            try Task.checkCancellation()
            let asset = AVURLAsset(url: destination)
            let video = try await asset.loadTracks(withMediaType: .video)
            guard !video.isEmpty,
                  FileManager.default.fileExists(atPath: destination.path),
                  ((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
            else { throw HLSMP4Error.invalidMP4 }
            if expectsAudio || alternateAudioURL != nil {
                guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                    throw HLSMP4Error.invalidMP4
                }
            }
            progress(1)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func assemble(_ plan: HLSMediaPlan, at destination: URL,
                          candidate: UniversalWebMediaCandidate,
                          session: URLSession,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        switch plan.format {
        case .ts:
            try await convertTransportStream(plan, destination: destination,
                                             candidate: candidate, progress: progress)
        case .fragmentedMP4:
            try await writeFragmentedMP4(plan, destination: destination,
                                         candidate: candidate, session: session,
                                         progress: progress)
        }
    }

    private func originReferer(_ page: URL) -> String {
        guard page.scheme?.lowercased() == "https", let host = page.host,
              URLSafetyPolicy.isPublic(page) else { return "" }
        return "https://" + host + "/"
    }

    private func fetchPlaylist(_ url: URL, candidate: UniversalWebMediaCandidate,
                               session: URLSession) async throws -> (String, URL) {
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
        return (text, actual)
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
        let ranges: [HLSByteRange?] = [plan.initializationRange] + plan.ranges
        guard resources.count == ranges.count else { throw HLSMP4Error.invalidPlaylist }

        for (index, url) in resources.enumerated() {
            try Task.checkCancellation()
            try DownloadStoragePolicy.check()
            var request = URLRequest(url: url)
            request.setValue(originReferer(candidate.pageURL), forHTTPHeaderField: "Referer")
            if let agent = candidate.userAgent, agent.count < 512,
               !agent.contains("\n"), !agent.contains("\r") {
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
            if let range = ranges[index] {
                request.setValue("bytes=\(range.offset)-\(range.lastByte)",
                                 forHTTPHeaderField: "Range")
                // Never allow a transformed gzip payload to invalidate offsets.
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            }
            let (temporary, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse,
                  let actual = response.url,
                  (try? HLSPlaylistPlanner.validate(actual)) != nil else {
                throw HLSMP4Error.unreachableSource
            }
            if let range = ranges[index] {
                let expected = "bytes \(range.offset)-\(range.lastByte)/"
                guard http.statusCode == 206,
                      (http.value(forHTTPHeaderField: "Content-Range") ?? "")
                        .hasPrefix(expected) else {
                    throw HLSMP4Error.unreachableSource
                }
                let length = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
                guard Int64(length) == range.length else {
                    throw HLSMP4Error.invalidMP4
                }
            } else {
                guard (200...299).contains(http.statusCode) else {
                    throw HLSMP4Error.unreachableSource
                }
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
