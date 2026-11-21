import Foundation

/// Parses untrusted JavaScript messages from individual WKWebView frames.
/// Actual frame identity comes from WebKit WKScriptMessage.frameInfo rather
/// than any URL the page claims to have.
enum UniversalMediaFrameResult {
    private struct Envelope: Decodable {
        let nonce: String
        let pageURL: String
        let title: String?
        let userAgent: String?
        let candidates: [Candidate]
        let selectedPlayer: SelectedPlayerPayload?
    }

    private struct SelectedPlayerPayload: Decodable {
        let mediaURL: String?
        let poster: String?
        let redGifsClipID: String?
        let isPiP: Bool?
        let isPlaying: Bool?
    }

    private struct Candidate: Decodable {
        let url: String
        let kind: String
        let playing: Bool?
        let poster: String?
        let association: String?
    }

    static func decode(_ json: String, frameURL: URL,
                       expectedNonce: String) throws -> [UniversalWebMediaCandidate] {
        guard let payload = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)),
              payload.nonce == expectedNonce,
              let page = URL(string: payload.pageURL),
              page.scheme?.lowercased() == "https",
              URLSafetyPolicy.isPublic(page),
              page.user == nil, page.password == nil,
              page.host?.lowercased() == frameURL.host?.lowercased() else {
            throw SocialExtractionError.unsupported("Embedded player did not match the inspected frame.")
        }
        let name = String((payload.title ?? "Embedded video").prefix(100))
        let agent = payload.userAgent.flatMap { value in
            value.count <= 512 && !value.contains("\n") && !value.contains("\r") ? value : nil
        }
        var found: [UniversalWebMediaCandidate] = []
        for raw in payload.candidates.prefix(80) {
            guard raw.url.count < 8192,
                  let media = URL(string: raw.url),
                  media.scheme?.lowercased() == "https",
                  media.user == nil, media.password == nil,
                  URLSafetyPolicy.isPublic(media),
                  let kind = UniversalWebMediaCandidate.Kind(rawValue: raw.kind),
                  !found.contains(where: { $0.url == media }) else { continue }
            found.append(UniversalWebMediaCandidate(
                url: media, pageURL: page, title: name,
                userAgent: agent, kind: kind, isPlaying: raw.playing ?? false,
                posterURL: raw.poster.flatMap { URL(string: $0) }.flatMap {
                    $0.scheme?.lowercased() == "https" && URLSafetyPolicy.isPublic($0)
                        && $0.user == nil && $0.password == nil ? $0 : nil
                },
                association: raw.playing == true ? .player :
                    UniversalWebMediaCandidate.Association(rawValue: raw.association ?? "") ?? .unknown
            ))
            if found.count == 24 { break }
        }
        return found
    }

    /// Decode only from a WebKit-authenticated frame and a user-initiated scan.
    /// Arbitrary video metadata in a resource entry is never a selected player.
    static func decodeSelectedPlayer(_ json: String, frameURL: URL,
                                     expectedNonce: String) throws -> BrowserSelectedPlayer? {
        guard let payload = try? JSONDecoder().decode(Envelope.self, from: Data(json.utf8)),
              payload.nonce == expectedNonce,
              let page = URL(string: payload.pageURL),
              page.scheme?.lowercased() == "https",
              URLSafetyPolicy.isPublic(page),
              page.user == nil, page.password == nil,
              page.host?.lowercased() == frameURL.host?.lowercased() else {
            throw SocialExtractionError.unsupported("Selected player did not match its WebKit frame.")
        }
        guard let selected = payload.selectedPlayer,
              selected.isPiP == true || selected.isPlaying == true else { return nil }
        let url = selected.mediaURL.flatMap {
            guard $0.count < 8192 else { return URL?.none }
            return URL(string: $0)
        }.flatMap { url -> URL? in
            guard url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  URLSafetyPolicy.isPublic(url) else { return nil }
            return url
        }
        let posterURL = selected.poster.flatMap {
            guard $0.count < 8192 else { return URL?.none }
            return URL(string: $0)
        }.flatMap { url -> URL? in
            guard url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil,
                  URLSafetyPolicy.isPublic(url) else { return nil }
            return url
        }
        let redGifsHost = page.host?.lowercased() == "redgifs.com" ||
            page.host?.lowercased().hasSuffix(".redgifs.com") == true
        let clipID = selected.redGifsClipID.flatMap {
            redGifsHost && RedGifsSelectedClipResolver.validID($0) ? $0 : nil
        }
        // Unknown blob/MSE is acceptable as a player identity, but cannot be
        // sent to the download service as a media URL.
        let agent = payload.userAgent.flatMap {
            $0.count < 512 && !$0.contains("\n") && !$0.contains("\r") ? $0 : nil
        }
        return BrowserSelectedPlayer(
            frameURL: frameURL, pageURL: page, streamURL: url,
            posterURL: posterURL, redGifsClipID: clipID,
            isPiP: selected.isPiP == true, isPlaying: selected.isPlaying == true,
            title: String((payload.title ?? "Currently playing video").prefix(100)),
            userAgent: agent)
    }

    static func merge(_ previous: [UniversalWebMediaCandidate],
                      _ incoming: [UniversalWebMediaCandidate]) -> [UniversalWebMediaCandidate] {
        var merged = previous
        for candidate in incoming {
            if let index = merged.firstIndex(where: { $0.url == candidate.url }) {
                // Prefer the most specific detection and active playback.
                let prior = merged[index]
                if (candidate.isPlaying && !prior.isPlaying) ||
                   (candidate.kind == .direct && prior.kind == .embed) ||
                   (prior.posterURL == nil && candidate.posterURL != nil) ||
                   (prior.association == .unknown && candidate.association != .unknown) {
                    merged[index] = candidate
                }
            } else {
                merged.append(candidate)
            }
        }
        merged.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            let first = rank($0.kind)
            let second = rank($1.kind)
            if first != second { return first < second }
            return $0.url.absoluteString < $1.url.absoluteString
        }
        return Array(merged.prefix(24))
    }

    private static func rank(_ kind: UniversalWebMediaCandidate.Kind) -> Int {
        switch kind {
        case .direct: return 0
        case .hls: return 1
        case .dash: return 2
        case .embed: return 3
        }
    }
}
