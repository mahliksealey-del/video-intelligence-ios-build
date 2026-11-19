import Foundation
import SwiftUI
import WebKit

/// User-initiated fallback for a TikTok page that the Python HTTP client
/// cannot read. The site runs in WKWebView on the iPhone, not a third-party API.
/// Only public page hydration data and its observed signed media URL are read.
enum TikTokBrowserResolution {
    private struct Payload: Decodable {
        let postID: String?
        let pageID: String?
        let mediaURL: String?
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
        guard let rawURL = payload.mediaURL, let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              Self.isTikTokMediaHost(host), URLSafetyPolicy.isPublic(url) else {
            throw SocialExtractionError.unsupported("TikTok did not expose a directly downloadable video. The browser may show a protected player or login page.")
        }
        var headers = ["Referer": "https://www.tiktok.com/"]
        if let agent = payload.userAgent, !agent.isEmpty, agent.count < 512 {
            headers["User-Agent"] = agent
        }
        let track = SocialMediaTrack(url: url, headers: headers, fileExtension: "mp4", chunkSize: nil, approximateBytes: nil)
        return ResolvedSocialMedia(kind: .progressive(track), title: payload.title ?? "TikTok video", suggestedFilename: "TikTok-\(postID).mp4")
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
        return JSON.stringify({postID: String(item?.id || ''), pageID, error: 'TikTok browser has not loaded public post metadata. Try playing the video and then retry.'});
      }
      const video = item.video || {};
      const urls = [];
      for (const row of (video.bitrateInfo || [])) {
        for (const candidate of (row.PlayAddr?.UrlList || [])) urls.push(candidate);
      }
      for (const candidate of [video.playAddr, video.downloadAddr]) {
        if (typeof candidate === 'string') urls.push(candidate);
      }
      const url = urls.find(s => typeof s === 'string' && s.startsWith('https://')) || null;
      return JSON.stringify({
        postID: String(item.id), pageID, mediaURL: url,
        title: String(item.desc || 'TikTok video').slice(0, 100),
        userAgent: navigator.userAgent
      });
    })();
    """#
}

/// Foreground WebKit fallback. User sees the real TikTok page before explicitly
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
                Text("Let TikTok load the video, then tap Use Video. This uses TikTok's own page on your iPhone.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                TikTokBrowserWebView(url: url, webView: $webView, statusText: $statusText)
                if let statusText {
                    Text(statusText).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
            }
            .navigationTitle("TikTok Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isInspecting ? "Checking…" : "Use Video") { inspect() }
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
