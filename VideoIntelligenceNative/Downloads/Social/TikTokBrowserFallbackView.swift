import Foundation
import SwiftUI
import WebKit

/// User-initiated TikTok browser resolver for a page that the Python HTTP client
/// cannot read. The site runs in WKWebView on the iPhone, not a third-party API.
/// Only public page hydration data and its observed signed media URL are read.
enum TikTokBrowserResolution {
    private struct Payload: Decodable {
        let postID: String?
        let pageID: String?
        let pageURL: String?
        let mediaURL: String?       // backward-compatible with the first prototype
        let mediaURLs: [String]?   // current player first, then TikTok metadata streams
        let title: String?
        let userAgent: String?
        let error: String?
    }

    static func decode(_ json: String) throws -> ResolvedSocialMedia {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(json.utf8)) else {
            throw SocialExtractionError.runtime("TikTok browser returned an invalid result.")
        }
        guard let postID = payload.postID, let pageID = payload.pageID,
              !postID.isEmpty, postID == pageID,
              postID.allSatisfy({ $0.isNumber }) else {
            throw SocialExtractionError.unsupported(payload.error ?? "TikTok did not expose an identifiable video post in the browser.")
        }
        let rawCandidates = (payload.mediaURLs ?? []) + [payload.mediaURL].compactMap { $0 }
        var candidates: [URL] = []
        for raw in rawCandidates {
            guard raw.count < 8192, let url = URL(string: raw),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  isTikTokMediaHost(host), URLSafetyPolicy.isPublic(url),
                  !candidates.contains(url) else { continue }
            candidates.append(url)
            if candidates.count >= 5 { break }
        }
        guard let first = candidates.first else {
            throw SocialExtractionError.unsupported("TikTok's browser played the page but did not expose a supported direct video stream.")
        }
        var headers = ["Referer": "https://www.tiktok.com/"]
        if let rawPage = payload.pageURL, let page = URL(string: rawPage),
           page.scheme?.lowercased() == "https",
           let host = page.host?.lowercased(),
           (host == "tiktok.com" || host.hasSuffix(".tiktok.com")) {
            headers["Referer"] = page.absoluteString
        }
        if let agent = payload.userAgent, !agent.isEmpty, agent.count < 512 {
            headers["User-Agent"] = agent
        }
        let track = SocialMediaTrack(url: first, headers: headers, fileExtension: "mp4",
                                     chunkSize: nil, approximateBytes: nil,
                                     alternativeURLs: Array(candidates.dropFirst()),
                                     useBrowserCookies: true)
        return ResolvedSocialMedia(kind: .progressive(track), title: payload.title ?? "TikTok video",
                                   suggestedFilename: "TikTok-\(postID).mp4")
    }

    static func isTikTokMediaHost(_ host: String) -> Bool {
        let bases = ["tiktok.com", "tiktokcdn.com", "tiktokcdn-eu.com", "tiktokcdn-us.com"]
        return bases.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Reads only TikTok's in-page public video hydration record, never cookies,
    /// credentials, arbitrary URLs, or third-party embedded assets.
    static let script = #"""
    (() => {
      const match = location.pathname.match(/\/video\/([0-9]+)/);
      const pageID = match ? match[1] : null;
      const el = document.getElementById('__UNIVERSAL_DATA_FOR_REHYDRATION__');
      let item = null;
      try {
        const scope = JSON.parse(el?.textContent || '{}').__DEFAULT_SCOPE__ || {};
        item = (scope['webapp.video-detail'] || scope['webapp.reflow.video.detail'])?.itemInfo?.itemStruct || null;
      } catch (_) {}
      if (!item || !pageID || String(item.id) !== pageID) {
        return JSON.stringify({postID: String(item?.id || ''), pageID, error: 'TikTok has not loaded public post data. Play the video, then retry.'});
      }

      const urls = [];
      const add = (candidate) => {
        if (typeof candidate === 'string' && candidate.startsWith('https://')) urls.push(candidate);
      };
      const addAddress = (candidate) => {
        if (Array.isArray(candidate)) { candidate.forEach(add); return; }
        if (typeof candidate === 'string') { add(candidate); return; }
        if (candidate && typeof candidate === 'object') {
          [candidate.UrlList, candidate.urlList, candidate.url_list].forEach(list => {
            if (Array.isArray(list)) list.forEach(add);
          });
        }
      };

      // Prefer the actual rendered player that successfully played on this iPhone
      // rather than choosing an untested H.265/alternate bitrate metadata URL.
      const players = [...document.querySelectorAll('video')];
      const active = players.find(v => !v.paused && v.readyState >= 2) || players.find(v => v.readyState >= 2);
      if (active) {
        add(active.currentSrc);
        add(active.src);
        active.querySelectorAll('source').forEach(source => add(source.src));
      }

      const video = item.video || {};
      addAddress(video.playAddr);
      addAddress(video.playAddrH264);
      for (const row of (video.bitrateInfo || [])) addAddress(row.PlayAddr || row.playAddr);
      addAddress(video.downloadAddr);
      const og = document.querySelector('meta[property="og:video"],meta[property="og:video:url"]');
      add(og?.content);

      return JSON.stringify({
        postID: String(item.id), pageID, pageURL: location.href,
        mediaURLs: [...new Set(urls)].slice(0, 12),
        title: String(item.desc || 'TikTok video').slice(0, 100),
        userAgent: navigator.userAgent
      });
    })();
    """#
}

/// Foreground WebKit resolver. User sees the real TikTok page before explicitly
/// requesting metadata extraction. It never sends video links to a remote resolver.
struct TikTokBrowserFallbackView: View {
    let url: URL
    let onResolved: (ResolvedSocialMedia) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var statusText: String?
    @State private var isInspecting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("Play the TikTok video, then tap Download. This uses the same browser session for the actual file transfer.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                TikTokBrowserWebView(url: url, webView: $webView, statusText: $statusText)
                if let statusText {
                    Text(statusText).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .navigationTitle("TikTok")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isInspecting ? "Checking…" : "Download") { inspect() }
                        .disabled(webView == nil || isInspecting)
                }
            }
        }
    }

    private func inspect() {
        guard let webView else { return }
        isInspecting = true
        statusText = nil
        webView.evaluateJavaScript(TikTokBrowserResolution.script) { value, error in
            Task { @MainActor in
                isInspecting = false
                if let error {
                    statusText = "TikTok's browser did not return media: \(error.localizedDescription)"
                    return
                }
                do {
                    guard let json = value as? String else {
                        throw SocialExtractionError.runtime("No media data was returned by the TikTok page.")
                    }
                    let media = try TikTokBrowserResolution.decode(json)
                    onResolved(media)
                    dismiss()
                } catch {
                    statusText = error.localizedDescription
                }
            }
        }
    }
}

private struct TikTokBrowserWebView: UIViewRepresentable {
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

    func updateUIView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let statusText: Binding<String?>
        init(statusText: Binding<String?>) { self.statusText = statusText }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                statusText.wrappedValue = "TikTok page could not load: \(error.localizedDescription)"
            }
        }
    }
}
