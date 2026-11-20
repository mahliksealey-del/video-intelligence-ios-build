import Foundation
import SwiftUI
import WebKit

/// Playback-first media discovery for user-opened ordinary websites.
/// It does not intercept privileged WebKit traffic or try to defeat DRM.
struct UniversalWebMediaCandidate: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case direct, hls, dash }

    let url: URL
    let pageURL: URL
    let title: String
    let userAgent: String?
    let kind: Kind
    let isPlaying: Bool

    var id: String { url.absoluteString }
}

enum UniversalWebMediaResolver {
    private struct Payload: Decodable {
        let pageURL: String
        let title: String?
        let userAgent: String?
        let candidates: [RawCandidate]
    }

    private struct RawCandidate: Decodable {
        let url: String
        let kind: String
        let playing: Bool?
    }

    static func decode(_ json: String, expectedPageURL: URL) throws -> [UniversalWebMediaCandidate] {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            throw SocialExtractionError.runtime("The webpage returned invalid playback detection data.")
        }
        guard let pageURL = URL(string: payload.pageURL),
              pageURL.scheme?.lowercased() == "https",
              pageURL.host?.lowercased() == expectedPageURL.host?.lowercased(),
              URLSafetyPolicy.isPublic(pageURL), pageURL.user == nil, pageURL.password == nil else {
            throw SocialExtractionError.unsupported("The website changed origin while scanning. Reopen or reload the page and retry.")
        }

        let name = String((payload.title ?? "Website video").prefix(100))
        let agent = payload.userAgent.flatMap { $0.count < 512 && !$0.contains("\n") && !$0.contains("\r") ? $0 : nil }
        var candidates: [UniversalWebMediaCandidate] = []
        for raw in payload.candidates.prefix(80) {
            guard raw.url.count < 8192,
                  let media = URL(string: raw.url),
                  media.scheme?.lowercased() == "https",
                  media.user == nil, media.password == nil,
                  URLSafetyPolicy.isPublic(media),
                  let kind = UniversalWebMediaCandidate.Kind(rawValue: raw.kind),
                  !candidates.contains(where: { $0.url == media }) else { continue }
            candidates.append(UniversalWebMediaCandidate(
                url: media, pageURL: pageURL, title: name,
                userAgent: agent, kind: kind, isPlaying: raw.playing == true
            ))
            if candidates.count == 12 { break }
        }
        candidates.sort {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            if ($0.kind == .direct) != ($1.kind == .direct) { return $0.kind == .direct }
            return false
        }
        return candidates
    }

    static func resolved(_ candidate: UniversalWebMediaCandidate) throws -> ResolvedSocialMedia {
        guard candidate.kind == .direct else {
            throw SocialExtractionError.unsupported(
                "An HLS/DASH stream was detected, but exportable segment processing is not ready in this version."
            )
        }
        // Only send the PAGE ORIGIN as Referer (never login paths or token-bearing query strings).
        guard var originParts = URLComponents(url: candidate.pageURL, resolvingAgainstBaseURL: false) else {
            throw MediaDownloadError.invalidURL
        }
        originParts.path = "/"
        originParts.query = nil
        originParts.fragment = nil
        guard let originURL = originParts.url else { throw MediaDownloadError.invalidURL }
        var headers = ["Referer": originURL.absoluteString]
        if let agent = candidate.userAgent { headers["User-Agent"] = agent }

        let media = SocialMediaTrack(
            url: candidate.url, headers: headers, fileExtension: "mp4",
            chunkSize: nil, approximateBytes: nil,
            browserSessionOrigin: candidate.pageURL
        )
        return ResolvedSocialMedia(kind: .progressive(media),
                                   title: candidate.title,
                                   suggestedFilename: "Website-Video.mp4")
    }

    /// Runs only after a user clicks "Find Video". Observes normal HTML video
    /// elements and visible resource records; never reads passwords or cookies.
    static let script = #"""
    (() => {
      const found = [];
      const seen = new Set();
      const classify = (url) => {
        const path = url.pathname.toLowerCase();
        if (path.endsWith('.m3u8')) return 'hls';
        if (path.endsWith('.mpd')) return 'dash';
        return 'direct';
      };
      const add = (raw, playing, source) => {
        try {
          if (!raw || typeof raw !== 'string') return;
          const value = new URL(raw, document.baseURI);
          if (value.protocol !== 'https:' || seen.has(value.href)) return;
          const path = value.pathname.toLowerCase();
          const extension = /\.(mp4|m4v|mov|webm|m3u8|mpd)$/.test(path);
          if (!extension && source !== 'player' && source !== 'meta') return;
          seen.add(value.href);
          found.push({url: value.href, kind: classify(value), playing: !!playing});
        } catch (_) {}
      };
      for (const video of document.querySelectorAll('video')) {
        const playing = !video.paused && video.readyState >= 2;
        add(video.currentSrc, playing, 'player');
        add(video.src, playing, 'player');
        video.querySelectorAll('source[src]').forEach(s => add(s.src, playing, 'player'));
      }
      const meta = document.querySelector('meta[property="og:video"], meta[property="og:video:url"], meta[name="twitter:player:stream"]');
      if (meta) add(meta.content, false, 'meta');
      try {
        const resources = performance.getEntriesByType('resource');
        for (const resource of resources.slice(-250)) add(resource.name, false, 'resource');
      } catch (_) {}
      return JSON.stringify({
        pageURL: location.href,
        title: String(document.title || 'Website video').slice(0, 100),
        userAgent: navigator.userAgent,
        candidates: found.slice(0, 80)
      });
    })();
    """#
}

/// Foreground browser allows ordinary website navigation and user-owned sign-in.
/// Only a user-selected direct video can be handed to the library downloader.
struct UniversalMediaBrowserView: View {
    let url: URL
    let mode: SocialDownloadMode
    let onResolved: (ResolvedSocialMedia, URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var candidates: [UniversalWebMediaCandidate] = []
    @State private var statusText: String?
    @State private var isInspecting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("Browse or sign in, play the video, then tap Find Video. Only media you select is saved.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                HStack {
                    Button("Back") { webView?.goBack() }
                        .disabled(webView?.canGoBack != true)
                    Button("Reload") { webView?.reload(); candidates = [] }
                        .disabled(webView == nil)
                    Spacer()
                    Button(isInspecting ? "Checking…" : "Find Video") { inspect() }
                        .disabled(webView == nil || isInspecting)
                        .buttonStyle(.borderedProminent)
                }.padding(.horizontal)
                UniversalBrowserWebView(url: url, webView: $webView, statusText: $statusText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !candidates.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Detected media").font(.headline)
                            ForEach(candidates) { candidate in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(candidate.isPlaying ? "Playing video" :
                                             candidate.kind == .direct ? "Video candidate" :
                                             candidate.kind == .hls ? "HLS playlist" : "DASH manifest")
                                            .font(.subheadline.weight(.semibold))
                                        Text(candidate.url.host ?? "Media")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if candidate.kind == .direct {
                                        Button("Save") { save(candidate) }.buttonStyle(.borderedProminent)
                                    } else {
                                        Text("Not yet exportable").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Divider()
                            }
                        }.padding(.horizontal)
                    }.frame(maxHeight: 180)
                }
                if let statusText {
                    Text(statusText).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .navigationTitle("Website Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func inspect() {
        guard let webView, let page = webView.url else { return }
        isInspecting = true
        statusText = nil
        candidates = []
        webView.evaluateJavaScript(UniversalWebMediaResolver.script) { value, error in
            Task { @MainActor in
                isInspecting = false
                if let error {
                    statusText = "Could not inspect this webpage: \(error.localizedDescription)"
                    return
                }
                do {
                    guard let json = value as? String else {
                        throw SocialExtractionError.runtime("The webpage did not return playback details.")
                    }
                    candidates = try UniversalWebMediaResolver.decode(json, expectedPageURL: page)
                    statusText = candidates.isEmpty
                        ? "No accessible media was found in this page. Try playing the video first. Cross-origin embedded players may need their original link."
                        : "Select a direct video to \(mode.rawValue.lowercased()). HLS and DASH require a later streaming upgrade."
                } catch {
                    statusText = error.localizedDescription
                }
            }
        }
    }

    private func save(_ candidate: UniversalWebMediaCandidate) {
        do {
            let media = try UniversalWebMediaResolver.resolved(candidate)
            onResolved(media, candidate.pageURL)
            dismiss()
        } catch {
            statusText = error.localizedDescription
        }
    }
}

private struct UniversalBrowserWebView: UIViewRepresentable {
    let url: URL
    @Binding var webView: WKWebView?
    @Binding var statusText: String?

    func makeCoordinator() -> Coordinator { Coordinator(statusText: $statusText) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let created = WKWebView(frame: .zero, configuration: configuration)
        created.navigationDelegate = context.coordinator
        created.load(URLRequest(url: url))
        DispatchQueue.main.async { self.webView = created }
        return created
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let statusText: Binding<String?>
        init(statusText: Binding<String?>) { self.statusText = statusText }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                statusText.wrappedValue = "The webpage could not load: \(error.localizedDescription)"
            }
        }
    }
}
