import Foundation

struct SocialFormatOption: Codable, Identifiable, Equatable, Sendable {
    let height: Int
    let codecLabel: String
    let approximateBytes: Int64?
    let formatID: String
    let isAdaptive: Bool
    var id: String { formatID }
}

struct SocialMediaTrack: Equatable, Sendable {
    let url: URL
    let headers: [String: String]
    let fileExtension: String
    let chunkSize: Int?
    let approximateBytes: Int64?

    // Only the user-initiated TikTok browser fallback sets these. The yt-dlp
    // paths for YouTube/Instagram keep their prior, unauthenticated behavior.
    let alternativeURLs: [URL]
    let useBrowserCookies: Bool
    // Only user-initiated general WebKit discoveries set this. Cookies must
    // domain-match BOTH the browsing origin and the media request host.
    let browserSessionOrigin: URL?

    init(url: URL, headers: [String: String], fileExtension: String,
         chunkSize: Int?, approximateBytes: Int64?,
         alternativeURLs: [URL] = [], useBrowserCookies: Bool = false,
         browserSessionOrigin: URL? = nil) {
        self.url = url
        self.headers = headers
        self.fileExtension = fileExtension
        self.chunkSize = chunkSize
        self.approximateBytes = approximateBytes
        self.alternativeURLs = alternativeURLs
        self.useBrowserCookies = useBrowserCookies
        self.browserSessionOrigin = browserSessionOrigin
    }

    func selecting(_ newURL: URL) -> SocialMediaTrack {
        SocialMediaTrack(url: newURL, headers: headers, fileExtension: fileExtension,
                         chunkSize: chunkSize, approximateBytes: approximateBytes,
                         useBrowserCookies: useBrowserCookies,
                         browserSessionOrigin: browserSessionOrigin)
    }
}

struct ResolvedSocialMedia: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case progressive(SocialMediaTrack); case adaptive(video: SocialMediaTrack, audio: SocialMediaTrack) }
    let kind: Kind
    let title: String
    let suggestedFilename: String
}

enum SocialFormatListing: Sendable { case ready(ResolvedSocialMedia); case choices([SocialFormatOption]) }

enum SocialExtractionError: LocalizedError, Equatable {
    case authenticationRequired(String)
    case unavailable(String)
    case rateLimited(String)
    case unsupported(String)
    case runtime(String)
    case mergeFailed

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "The provider requires sign-in or has restricted anonymous access. For Instagram, sign in through Get Media and retry."
        case .unavailable: return "This media is private, removed, geo-restricted, or unavailable."
        case .rateLimited: return "The provider is rate-limiting requests. Wait and try again."
        case .unsupported(let detail): return "The provider could not supply an iPhone-compatible stream. \(detail)"
        case .runtime(let detail): return "The on-device extractor failed. \(detail)"
        case .mergeFailed: return "The separate audio and video streams could not be merged into a playable MP4."
        }
    }
}

private struct TrackPayload: Decodable {
    let url: String; let headers: [String: String]?; let ext: String?; let chunkSize: Int?; let approximateBytes: Int64?
    enum CodingKeys: String, CodingKey { case url, headers, ext; case chunkSize = "chunk_size"; case approximateBytes = "approx_bytes" }
}

private struct ExtractionEnvelope: Decodable {
    let ok: Bool; let kind: String?; let title: String?; let filename: String?; let media: TrackPayload?; let video: TrackPayload?; let audio: TrackPayload?; let options: [OptionPayload]?; let errorKind: String?; let detail: String?
    enum CodingKeys: String, CodingKey { case ok, kind, title, filename, media, video, audio, options, detail; case errorKind = "error_kind" }
}

private struct OptionPayload: Decodable {
    let height: Int; let codec: String?; let approximateBytes: Int64?; let formatID: String; let adaptive: Bool
    enum CodingKeys: String, CodingKey { case height, codec, adaptive; case approximateBytes = "approx_bytes"; case formatID = "format_id" }
}

enum SocialExtractionDecoder {
    static func listing(_ data: Data) throws -> SocialFormatListing {
        let envelope = try decodeEnvelope(data)
        if envelope.kind == "choices" {
            return .choices((envelope.options ?? []).map { SocialFormatOption(height: $0.height, codecLabel: $0.codec ?? "", approximateBytes: $0.approximateBytes, formatID: $0.formatID, isAdaptive: $0.adaptive) })
        }
        return .ready(try resolved(envelope))
    }

    static func resolved(_ data: Data) throws -> ResolvedSocialMedia { try resolved(decodeEnvelope(data)) }

    private static func decodeEnvelope(_ data: Data) throws -> ExtractionEnvelope {
        guard let envelope = try? JSONDecoder().decode(ExtractionEnvelope.self, from: data) else { throw SocialExtractionError.runtime("Malformed extractor response.") }
        guard envelope.ok else { throw map(envelope.errorKind ?? "runtime", envelope.detail ?? "") }
        return envelope
    }

    private static func resolved(_ envelope: ExtractionEnvelope) throws -> ResolvedSocialMedia {
        let title = envelope.title ?? "Downloaded Media"
        if envelope.kind == "progressive", let media = track(envelope.media) { return ResolvedSocialMedia(kind: .progressive(media), title: title, suggestedFilename: envelope.filename ?? title + ".mp4") }
        if envelope.kind == "adaptive", let video = track(envelope.video), let audio = track(envelope.audio) { return ResolvedSocialMedia(kind: .adaptive(video: video, audio: audio), title: title, suggestedFilename: envelope.filename ?? title + ".mp4") }
        throw SocialExtractionError.runtime("Extractor returned no usable tracks.")
    }

    private static func track(_ payload: TrackPayload?) -> SocialMediaTrack? {
        guard let payload, let url = URL(string: payload.url), URLSafetyPolicy.isPublic(url) else { return nil }
        return SocialMediaTrack(url: url, headers: payload.headers ?? [:], fileExtension: payload.ext ?? url.pathExtension, chunkSize: payload.chunkSize, approximateBytes: payload.approximateBytes)
    }

    private static func map(_ kind: String, _ detail: String) -> SocialExtractionError {
        switch kind {
        case "requires_auth", "restricted_or_empty": return .authenticationRequired(detail)
        case "unavailable": return .unavailable(detail)
        case "rate_limited": return .rateLimited(detail)
        case "unsupported", "needs_ffmpeg": return .unsupported(detail)
        default: return .runtime(detail)
        }
    }
}
