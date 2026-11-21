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
