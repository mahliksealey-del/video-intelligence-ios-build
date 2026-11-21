import Foundation
import SwiftUI
import WebKit

/// Playback-first media discovery for user-opened ordinary websites.
/// It does not intercept privileged WebKit traffic or try to defeat DRM.
struct UniversalWebMediaCandidate: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case direct, hls, dash, embed }

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
            if ($0.kind == .embed) != ($1.kind == .embed) { return $0.kind == .embed }
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

/// Explicit, optional popup controls. Never auto-consent, dismiss a paywall,
/// or evaluate executable code from a webpage as native Swift.
enum UniversalBrowserPopupPolicy {
    static func canOpenNewWindow(_ url: URL?, userInitiated: Bool) -> Bool {
        guard userInitiated, let url else { return false }
        return url.scheme?.lowercased() == "https" && URLSafetyPolicy.isPublic(url)
    }

    /// Click only an explicit CLOSE/DISMISS control in a visible popup.
    /// The user invokes this after inspecting the page; no auto-acceptance.
    static let dismissScript = #"""
    (() => {
      const visible = (el) => {
        const r = el.getBoundingClientRect();
        const s = getComputedStyle(el);
        return r.width > 0 && r.height > 0 && s.display !== 'none' &&
               s.visibility !== 'hidden' && s.opacity !== '0';
      };
      const containers = [...document.querySelectorAll(
        'dialog[open], [role="dialog"], [aria-modal="true"], [class*="modal"], [class*="popup"], [id*="popup"], [class*="overlay"]'
      )].filter(visible).slice(0, 30);
      const allowed = /^(close|close ad|close advertisement|dismiss|dismiss ad|skip ad|not now|no thanks|×|✕|x)$/i;
      for (const container of containers) {
        // Do not dismiss authorization, age, payment, verification or subscription gates.
        const classification = [container.getAttribute('aria-label') || '',
          container.getAttribute('id') || '', String(container.className || '')].join(' ');
        if (/paywall|login|sign.in|payment|checkout|purchase|captcha|age.gate|verification/i.test(classification)) continue;
        const buttons = container.querySelectorAll('button, [role="button"]');
        for (const button of buttons) {
          if (!visible(button) || button.closest('a[href]')) continue;
          const label = (button.getAttribute('aria-label') || button.textContent || '').trim();
          if (!allowed.test(label)) continue;
          button.click();
          return 'An available popup close button was pressed. Tap Find Video after playback starts.';
        }
      }
      return 'No ordinary popup close button was found. Close the popup manually or finish any required sign-in or consent choice.';
    })();
    """#
}

/// Address-bar normalization and validation shared by keyboard Go and button Go.
/// Accepts HTTPS web addresses without requiring users to type the scheme.
enum UniversalBrowserAddress {
    static func resolve(_ typed: String) throws -> URL {
        let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else {
            throw MediaDownloadError.invalidURL
        }
        // Do not mistake "example.com:8443" for a custom URL scheme.
        let lowered = value.lowercased()
        let hasScheme = lowered.hasPrefix("https:") ||
                        lowered.hasPrefix("http:") ||
                        value.contains("://")
        let url = try MediaURLValidator.validate(hasScheme ? value : "https://" + value)
        guard url.user == nil, url.password == nil else {
            throw MediaDownloadError.invalidURL
        }
        return url
    }
}

/// Foreground browser allows ordinary website navigation and user-owned sign-in.
/// Only a user-selected direct video can be handed to the library downloader.
struct UniversalMediaBrowserView: View {
    @EnvironmentObject private var library: LibraryStore
    let url: URL
    let mode: SocialDownloadMode
    let onResolved: (ResolvedSocialMedia, URL) -> Void
    // Dedicated extraction for YouTube/Shorts and Instagram, or the working
    // TikTok browser, must supersede generic HTML video discovery.
    let onProviderLink: (URL, SocialDownloadMode) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var currentPageURL: URL?
    @State private var addressText = ""
    @State private var approvedAddressNavigation: URL?
    @FocusState private var addressFocused: Bool
    @State private var candidates: [UniversalWebMediaCandidate] = []
    @State private var statusText: String?
    @State private var isInspecting = false
    @State private var scanNonce: String?
    @AppStorage("VIWebsiteAdBlockingEnabled") private var blockAds = true
    @State private var stayOnSite = false

    private var providerPage: (url: URL, provider: MediaProvider)? {
        guard let page = currentPageURL ?? webView?.url,
              (try? MediaURLValidator.validate(page.absoluteString)) != nil else { return nil }
        let detected = MediaProvider.detect(page)
        return detected == .direct ? nil : (page, detected)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("Browse or sign in, play the video, then tap Find Video. Only media you select is saved.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    TextField("Enter website address", text: $addressText)
                        .font(.footnote)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit { navigateToAddress() }
                        .accessibilityLabel("Website address")
                    Button("Go") { navigateToAddress() }
                        .font(.footnote.weight(.semibold))
                        .disabled(webView == nil || addressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal)
                HStack(spacing: 10) {
                    Button { webView?.goBack() } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back")
                        .disabled(webView?.canGoBack != true)
                    Button { webView?.reload(); candidates = [] } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Reload")
                        .disabled(webView == nil)
                    Button("Dismiss Popup") { dismissPopup() }
                        .disabled(webView == nil)
                        .font(.footnote)
                     Spacer(minLength: 0)
                    Button(isInspecting ? "Checking…" : "Find Video") { inspect() }
                        .disabled(webView == nil || isInspecting)
                        .buttonStyle(.borderedProminent)
                }.padding(.horizontal)
                if let known = providerPage {
                    HStack(spacing: 8) {
                        Label("\(known.provider.rawValue) detected", systemImage: "arrow.down.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use \(known.provider.rawValue) Downloader") { useProviderDownloader() }
                            .font(.footnote.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal)
                }
                HStack(spacing: 16) {
                    Toggle("Block Ads", isOn: $blockAds)
                    Toggle("Stay on Site", isOn: $stayOnSite)
                }.font(.caption).padding(.horizontal)
                UniversalBrowserWebView(url: url, webView: $webView,
                                        pageURL: $currentPageURL,
                                        approvedAddressNavigation: $approvedAddressNavigation,
                                        statusText: $statusText, candidates: $candidates,
                                        scanNonce: $scanNonce, blockAds: blockAds,
                                        stayOnSite: stayOnSite)
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
                                             candidate.kind == .hls ? "HLS playlist" :
                                             candidate.kind == .dash ? "DASH manifest" : "Embedded player")
                                            .font(.subheadline.weight(.semibold))
                                        Text(candidate.url.host ?? "Media")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if candidate.kind == .direct {
                                        Button("Save") { save(candidate) }.buttonStyle(.borderedProminent)
                                    } else if candidate.kind == .hls {
                                        Button("Save Offline") { saveHLS(candidate) }
                                            .buttonStyle(.borderedProminent)
                                            .disabled(library.socialDownloadProgress != nil)
                                    } else if candidate.kind == .embed {
                                        Button("Open Player") { openEmbedded(candidate) }
                                            .buttonStyle(.bordered)
                                    } else {
                                        Text("Stream detected").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Divider()
                            }
                        }.padding(.horizontal)
                    }.frame(maxHeight: 180)
                }
                if let progress = library.socialDownloadProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                        Text("\(Int(progress * 100))%")
                            .font(.caption.monospacedDigit())
                        Button("Cancel") { library.cancelOperation() }
                            .font(.caption)
                    }
                    .padding(.horizontal)
                }
                if let statusText {
                    Text(statusText).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .navigationTitle("Website Browser")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if addressText.isEmpty { addressText = currentPageURL?.absoluteString ?? url.absoluteString }
            }
            .onChange(of: currentPageURL) { latest in
                if !addressFocused, let latest {
                    addressText = latest.absoluteString
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private func navigateToAddress() {
        guard let webView else { return }
        do {
            let destination = try UniversalBrowserAddress.resolve(addressText)
            addressFocused = false
            scanNonce = nil
            candidates = []
            isInspecting = false
            approvedAddressNavigation = destination

            // The site lock is useful against ad redirects but a deliberately
            // entered new address should always be a user-authorized pivot.
            let changesSite = webView.url?.host?.lowercased() != destination.host?.lowercased()
            if stayOnSite && changesSite {
                stayOnSite = false
                statusText = "Opened your requested website. Stay on Site was turned off for navigation; you can enable it again."
            } else {
                statusText = nil
            }
            webView.load(URLRequest(url: destination))
        } catch {
            statusText = "Invalid website address: \(error.localizedDescription)"
        }
    }

    private func dismissPopup() {
        guard let webView else { return }
        webView.evaluateJavaScript(UniversalBrowserPopupPolicy.dismissScript) { result, error in
            Task { @MainActor in
                if let error {
                    statusText = "Unable to dismiss popup: \(error.localizedDescription)"
                } else {
                    statusText = result as? String ?? "Popup action completed. Try playing the video."
                }
            }
        }
    }

    private func inspect() {
        // YouTube's SABR/JS challenge and Instagram/TikTok provider workflows
        // are not ordinary public HTML5 video URLs. Dispatch to their dedicated
        // routes instead of returning "No media found" from the generic probe.
        if providerPage != nil {
            useProviderDownloader()
            return
        }
        guard let webView, let page = webView.url else { return }
        isInspecting = true
        statusText = "Scanning this page and its embedded players…"
        candidates = []
        let nonce = UUID().uuidString
        scanNonce = nonce
        // The all-frame probe relays results from cross-origin iframe players.
        webView.evaluateJavaScript("window.postMessage({type:'vi.scan.v1',nonce:'\(nonce)',depth:0},'*');") { _, _ in }
        // Preserve the proven top-document discovery as a fallback.
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
                    let topFrame = try UniversalWebMediaResolver.decode(json, expectedPageURL: page)
                    candidates = UniversalMediaFrameResult.merge(candidates, topFrame)
                    statusText = candidates.isEmpty
                        ? "No media yet. Play the video, retry Find Video, or open a detected embedded player."
                        : "Choose Save for direct video, Save Offline for supported HLS video-on-demand, or Open Player for embedded media. DASH and MP4 stream export are not yet available."
                } catch {
                    statusText = error.localizedDescription
                }
            }
        }
    }

    private func saveHLS(_ candidate: UniversalWebMediaCandidate) {
        guard HLSOfflineDownloadService.supports(candidate) else {
            statusText = "This HLS playlist cannot be downloaded safely."
            return
        }
        library.downloadHLS(candidate)
        statusText = "Saving an offline HLS package. When finished, open it in your library. This is not an exportable MP4; live and protected streams may fail."
    }

    private func useProviderDownloader() {
        guard let known = providerPage else { return }
        scanNonce = nil
        candidates = []
        onProviderLink(known.url, mode)
        dismiss()
    }

    private func openEmbedded(_ candidate: UniversalWebMediaCandidate) {
        guard candidate.kind == .embed, let webView,
              candidate.url.scheme?.lowercased() == "https",
              URLSafetyPolicy.isPublic(candidate.url) else { return }
        statusText = "Opening the video player's page in the browser. Play it, then use Find Video again."
        scanNonce = nil
        candidates = []
        webView.load(URLRequest(url: candidate.url))
    }

    private func save(_ candidate: UniversalWebMediaCandidate) {
        do {
            let media = try UniversalWebMediaResolver.resolved(candidate)
            onResolved(media, webView?.url ?? candidate.pageURL)
            dismiss()
        } catch {
            statusText = error.localizedDescription
        }
    }
}

private struct UniversalBrowserWebView: UIViewRepresentable {
    let url: URL
    @Binding var webView: WKWebView?
    @Binding var pageURL: URL?
    @Binding var approvedAddressNavigation: URL?
    @Binding var statusText: String?
    @Binding var candidates: [UniversalWebMediaCandidate]
    @Binding var scanNonce: String?
    let blockAds: Bool
    let stayOnSite: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(statusText: $statusText, pageURL: $pageURL,
                    approvedAddressNavigation: $approvedAddressNavigation,
                    candidates: $candidates, scanNonce: $scanNonce,
                    blockAds: blockAds, stayOnSite: stayOnSite)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let userContent = configuration.userContentController
        userContent.addUserScript(WKUserScript(source: UniversalMediaFrameProbe.script,
                                               injectionTime: .atDocumentStart,
                                               forMainFrameOnly: false))
        userContent.add(context.coordinator, name: UniversalMediaFrameProbe.handlerName)
        let created = WKWebView(frame: .zero, configuration: configuration)
        created.navigationDelegate = context.coordinator
        created.uiDelegate = context.coordinator
        context.coordinator.configureBlocker(created, enabled: blockAds,
                                              initialURL: url)
        DispatchQueue.main.async { self.webView = created }
        return created
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.updateBlocker(uiView, enabled: blockAds)
        context.coordinator.updateSiteLock(enabled: stayOnSite)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private let statusText: Binding<String?>
        private let pageURL: Binding<URL?>
        private let approvedAddressNavigation: Binding<URL?>
        private let candidates: Binding<[UniversalWebMediaCandidate]>
        private let scanNonce: Binding<String?>
        private var blockerEnabled: Bool
        private var lockSiteEnabled: Bool
        private var blockerGeneration = 0

        init(statusText: Binding<String?>, pageURL: Binding<URL?>,
             approvedAddressNavigation: Binding<URL?>,
             candidates: Binding<[UniversalWebMediaCandidate]>,
             scanNonce: Binding<String?>, blockAds: Bool,
             stayOnSite: Bool) {
            self.statusText = statusText
            self.pageURL = pageURL
            self.approvedAddressNavigation = approvedAddressNavigation
            self.candidates = candidates
            self.scanNonce = scanNonce
            self.blockerEnabled = blockAds
            self.lockSiteEnabled = stayOnSite
        }

        func configureBlocker(_ webView: WKWebView, enabled: Bool, initialURL: URL) {
            applyBlocker(webView, enabled: enabled, initialURL: initialURL)
        }

        func updateSiteLock(enabled: Bool) {
            lockSiteEnabled = enabled
        }

        func updateBlocker(_ webView: WKWebView, enabled: Bool) {
            guard blockerEnabled != enabled else { return }
            applyBlocker(webView, enabled: enabled, initialURL: nil)
        }

        private func applyBlocker(_ webView: WKWebView, enabled: Bool, initialURL: URL?) {
            blockerEnabled = enabled
            blockerGeneration += 1
            let generation = blockerGeneration
            let userContent = webView.configuration.userContentController
            userContent.removeAllContentRuleLists()
            guard enabled else {
                if let initialURL { webView.load(URLRequest(url: initialURL)) }
                else { webView.reload() }
                return
            }
            NativeAdBlocker.prepare { [weak self, weak webView] list, error in
                DispatchQueue.main.async {
                    guard let self, let webView,
                          self.blockerEnabled,
                          self.blockerGeneration == generation else { return }
                    if let list { webView.configuration.userContentController.add(list) }
                    else if let error {
                        self.statusText.wrappedValue = "The optional ad rules could not load: \(error.localizedDescription). Browser playback still works."
                    }
                    if let initialURL { webView.load(URLRequest(url: initialURL)) }
                    else { webView.reload() }
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == UniversalMediaFrameProbe.handlerName,
                  let json = message.body as? String,
                  json.count < 100_000,
                  let expectedNonce = scanNonce.wrappedValue,
                  let frameURL = message.frameInfo.request.url,
                  frameURL.scheme?.lowercased() == "https",
                  URLSafetyPolicy.isPublic(frameURL) else { return }
            Task { @MainActor in
                guard self.scanNonce.wrappedValue == expectedNonce else { return }
                do {
                    let result = try UniversalMediaFrameResult.decode(
                        json, frameURL: frameURL, expectedNonce: expectedNonce)
                    self.candidates.wrappedValue = UniversalMediaFrameResult.merge(
                        self.candidates.wrappedValue, result)
                    if !self.candidates.wrappedValue.isEmpty {
                        self.statusText.wrappedValue = "Found media from the page or embedded players. Select Save or Open Player."
                    }
                } catch { /* Ignore malformed third-party frame messages. */ }
            }
        }

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            scanNonce.wrappedValue = nil
            candidates.wrappedValue = []
        }

        func webView(_ webView: WKWebView,
                     didCommit navigation: WKNavigation!) {
            approvedAddressNavigation.wrappedValue = nil
            pageURL.wrappedValue = webView.url
        }

        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {
            pageURL.wrappedValue = webView.url
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // A URL explicitly submitted through the address bar overrides
            // the optional cross-site ad-redirect guard exactly once.
            if navigationAction.targetFrame?.isMainFrame == true,
               let approved = approvedAddressNavigation.wrappedValue,
               approved == navigationAction.request.url {
                approvedAddressNavigation.wrappedValue = nil
                decisionHandler(.allow)
                return
            }
            if VideoSiteNavigationLock.shouldBlock(
                currentPage: webView.url,
                nextPage: navigationAction.request.url,
                isMainFrame: navigationAction.targetFrame?.isMainFrame == true,
                enabled: lockSiteEnabled) {
                statusText.wrappedValue = "Stay on Site blocked an external redirect. Turn it off temporarily for sign-in or legitimate links."
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            let userTapped = navigationAction.navigationType == .linkActivated
            if UniversalBrowserPopupPolicy.canOpenNewWindow(navigationAction.request.url,
                                                             userInitiated: userTapped) {
                webView.load(navigationAction.request)
            } else {
                statusText.wrappedValue = "An unsolicited popup window was blocked. Use ordinary links to navigate to the video."
            }
            return nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled {
                statusText.wrappedValue = "The webpage could not load: \(error.localizedDescription)"
            }
        }
    }
}
