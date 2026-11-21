import Foundation

/// Snapshot of the selected HTML5 video, reported by the same WebKit frame
/// which owns that player. This is not a packet capture or evidence that a
/// blob: URL is an exportable media file.
struct BrowserSelectedPlayer: Equatable, Sendable {
    let frameURL: URL
    let pageURL: URL
    let streamURL: URL?
    let posterURL: URL?
    let redGifsClipID: String?
    let isPiP: Bool
    let isPlaying: Bool
    let title: String
    let userAgent: String?

    var priority: Int { isPiP ? 2 : isPlaying ? 1 : 0 }
    var identity: String {
        if let redGifsClipID { return "redgifs:" + redGifsClipID.lowercased() }
        if let streamURL { return streamURL.absoluteString }
        return frameURL.absoluteString + "#unresolved-player"
    }
    var clipPageURL: URL? {
        guard let redGifsClipID else { return nil }
        return URL(string: "https://www.redgifs.com/watch/" + redGifsClipID)
    }

    var directCandidate: UniversalWebMediaCandidate? {
        guard let streamURL, URLSafetyPolicy.isPublic(streamURL),
              streamURL.scheme?.lowercased() == "https",
              let kind = Self.classify(streamURL) else { return nil }
        return UniversalWebMediaCandidate(
            url: streamURL, pageURL: pageURL,
            title: title, userAgent: userAgent, kind: kind,
            isPlaying: isPlaying, posterURL: posterURL, association: .player)
    }

    static func classify(_ url: URL) -> UniversalWebMediaCandidate.Kind? {
        switch url.pathExtension.lowercased() {
        case "m3u8": return .hls
        case "mp4", "m4v", "mov": return .direct
        case "mpd": return .dash
        default: return nil
        }
    }
}

/// If two frames both report playing video and neither has entered PiP,
/// selecting an arbitrary first result could save the wrong short.
enum BrowserPlayerSelectionPolicy {
    static func single(_ reports: [BrowserSelectedPlayer]) -> BrowserSelectedPlayer? {
        let active = reports.filter { $0.priority > 0 }
        guard let highest = active.map(\.priority).max() else { return nil }
        let strongest = active.filter { $0.priority == highest }
        let identities = Set(strongest.map(\.identity))
        guard identities.count == 1 else { return nil }
        return strongest.first
    }
}

/// Only a user-triggered capture invokes this optional RedGifs-specific
/// resolver. The feed's real clip ID, not a nearby playlist, determines the
/// metadata request. Public API behavior can change independently of WebKit.
struct RedGifsSelectedClipResolver {
    enum ResolutionError: LocalizedError {
        case invalidClipID
        case missingToken
        case noPlayableMedia

        var errorDescription: String? {
            switch self {
            case .invalidClipID: "The active RedGifs clip did not have a valid identifier."
            case .missingToken: "RedGifs did not issue a public media lookup token."
            case .noPlayableMedia: "RedGifs did not provide a downloadable direct video or HLS source for this clip."
            }
        }
    }

    private struct TokenResponse: Decodable { let token: String? }
    private struct VideoResponse: Decodable {
        let gif: Video?
        struct Video: Decodable {
            let urls: VideoURLs?
        }
        struct VideoURLs: Decodable {
            let hd: String?
            let sd: String?
            let hls: String?
            let poster: String?
            let thumbnail: String?
        }
    }

    static func validID(_ id: String) -> Bool {
        (3...90).contains(id.count) &&
        id.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) ||
            ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95
        }
    }

    static func decodedMediaURL(_ value: String?) -> URL? {
        guard let value, value.count < 8192, let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              URLSafetyPolicy.isPublic(url) else { return nil }
        return url
    }

    func resolve(_ selection: BrowserSelectedPlayer) async throws -> UniversalWebMediaCandidate {
        guard let id = selection.redGifsClipID, Self.validID(id) else {
            throw ResolutionError.invalidClipID
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let authURL = URL(string: "https://api.redgifs.com/v2/auth/temporary")!
        let (tokenData, tokenResponse) = try await session.data(from: authURL)
        guard let response = tokenResponse as? HTTPURLResponse,
              response.statusCode == 200,
              let token = try JSONDecoder().decode(TokenResponse.self, from: tokenData).token,
              !token.isEmpty, token.count < 4096 else {
            throw ResolutionError.missingToken
        }
        let detailURL = URL(string: "https://api.redgifs.com/v2/gifs/" + id)!
        var request = URLRequest(url: detailURL)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (body, httpResponse) = try await session.data(for: request)
        guard (httpResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw ResolutionError.noPlayableMedia
        }
        let decoded = try JSONDecoder().decode(VideoResponse.self, from: body)
        guard let urls = decoded.gif?.urls else { throw ResolutionError.noPlayableMedia }
        // Prefer exportable HD or SD MP4 from this exact clip. HLS is the
        // preserved fallback, using the already tested Apple offline path.
        let preferred = [urls.hd, urls.sd, urls.hls]
            .compactMap { Self.decodedMediaURL($0) }
            .first(where: { BrowserSelectedPlayer.classify($0) != nil })
        guard let source = preferred,
              let kind = BrowserSelectedPlayer.classify(source),
              kind == .direct || kind == .hls else {
            throw ResolutionError.noPlayableMedia
        }
        let poster = Self.decodedMediaURL(urls.poster) ??
                     Self.decodedMediaURL(urls.thumbnail) ?? selection.posterURL
        return UniversalWebMediaCandidate(
            url: source, pageURL: selection.pageURL,
            title: "RedGifs " + id, userAgent: selection.userAgent,
            kind: kind, isPlaying: selection.isPlaying,
            posterURL: poster, association: .player)
    }
}
