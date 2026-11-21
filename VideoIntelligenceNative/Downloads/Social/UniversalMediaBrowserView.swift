import AVFoundation
import Foundation
import SwiftUI
import UIKit
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
    var posterURL: URL? = nil
    // Only native HTML5 player URLs can be confirmed as currently playing.
    // A single manifest in an active frame is a possible match, not proof.
    enum Association: String, Sendable { case player, possible, unknown }
    var association: Association = .unknown

    var id: String { url.absoluteString }
}

/// One-tap view for an explicitly associated playing video. We never choose
/// a random manifest from multiple unrelated resource requests.
enum UniversalMediaFocus {
    static func preferred(_ candidates: [UniversalWebMediaCandidate]) -> [UniversalWebMediaCandidate] {
        let playable = candidates.filter { $0.kind == .hls || $0.kind == .direct }
        let playing = playable.filter { $0.isPlaying || $0.association == .player }
        if !playing.isEmpty { return playing }
        let possible = playable.filter { $0.association == .possible }
        if possible.count == 1 { return possible }
        // One valid candidate is easier to identify, but label it as
        // unverified and offer Preview rather than claiming it is playing.
        return playable.count == 1 ? playable : []
    }
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
        let poster: String?
        let association: String?
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
                userAgent: agent, kind: kind, isPlaying: raw.playing == true,
                posterURL: raw.poster.flatMap { URL(string: $0) }.flatMap {
                    $0.scheme?.lowercased() == "https" && URLSafetyPolicy.isPublic($0)
                        && $0.user == nil && $0.password == nil ? $0 : nil
                },
                association: raw.playing == true ? .player :
                    UniversalWebMediaCandidate.Association(rawValue: raw.association ?? "") ?? .unknown
            ))
            if candidates.count == 24 { break }
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
      const add = (raw, playing, source, poster) => {
        try {
          if (!raw || typeof raw !== 'string') return;
          const value = new URL(raw, document.baseURI);
          if (value.protocol !== 'https:' || seen.has(value.href)) return;
          const path = value.pathname.toLowerCase();
          const extension = /\.(mp4|m4v|mov|webm|m3u8|mpd)$/.test(path);
          if (!extension && source !== 'player' && source !== 'meta') return;
          seen.add(value.href);
          found.push({url: value.href, kind: classify(value), playing: !!playing,
                      association: playing && source === 'player' ? 'player' : 'unknown',
                      poster: source === 'player' && poster ? poster : null});
        } catch (_) {}
      };
      const activePlayers = [...document.querySelectorAll('video')].filter(video => {
        const r = video.getBoundingClientRect();
        return !video.paused && video.readyState >= 2 && r.width > 20 && r.height > 20 &&
               r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
      });
      for (const video of document.querySelectorAll('video')) {
        const playing = activePlayers.includes(video);
        const poster = video.poster || null;
        add(video.currentSrc, playing, 'player', poster);
        add(video.src, playing, 'player', poster);
        video.querySelectorAll('source[src]').forEach(s => add(s.src, playing, 'player', poster));
      }
      const meta = document.querySelector('meta[property="og:video"], meta[property="og:video:url"], meta[name="twitter:player:stream"]');
      if (meta) add(meta.content, false, 'meta');
      try {
        const resources = performance.getEntriesByType('resource');
        for (const resource of resources.slice(-250)) add(resource.name, false, 'resource');
      } catch (_) {}
      // Opaque blob/MSE players do not expose their playlist in currentSrc.
      // Only label a manifest "possible" when exactly one is seen in a frame
      // containing exactly one actively visible video; this is not a guarantee.
      const hls = found.filter(item => item.kind === 'hls');
      if (activePlayers.length === 1 && hls.length === 1 &&
          !found.some(item => item.playing && (item.kind === 'hls' || item.kind === 'direct'))) {
        hls[0].association = 'possible';
      }
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
    @State private var showDownloads = false
    @State private var previewStream: BrowserMediaPreview?
    @State private var showAllDetectedStreams = false
    @State private var selectedPlayer: BrowserSelectedPlayer?
    @State private var capturedCandidate: UniversalWebMediaCandidate?
    @State private var captureIssue: String?
    @State private var isResolvingCapturedClip = false

    private var activeBrowserDownloadCount: Int {
        library.browserDownloads.filter {
            $0.status == .running || $0.status == .queued
        }.count
    }

    private var displayedCandidates: [UniversalWebMediaCandidate] {
        // Never select the first or most recently requested HLS stream just
        // because it happens to be near an active video in a feed.
        if showAllDetectedStreams { return candidates }
        return capturedCandidate.map { [$0] } ?? []
    }

    private var providerPage: (url: URL, provider: MediaProvider)? {
        guard let page = currentPageURL ?? webView?.url,
              (try? MediaURLValidator.validate(page.absoluteString)) != nil else { return nil }
        let detected = MediaProvider.detect(page)
        return detected == .direct ? nil : (page, detected)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("Play a video (or use PiP), then tap Get Video. Preview that exact clip before saving.")
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
                    Button(isInspecting ? "Checking…" : "Get Video") { inspect() }
                        .accessibilityLabel("Capture currently playing or Picture in Picture video")
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
                HStack {
                    Button { showDownloads = true } label: {
                        Label("Downloads (\(activeBrowserDownloadCount))", systemImage: "arrow.down.circle")
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityLabel("Open download center")
                    Spacer()
                    Text("Save videos without leaving this page")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                UniversalBrowserWebView(url: url, webView: $webView,
                                        pageURL: $currentPageURL,
                                        approvedAddressNavigation: $approvedAddressNavigation,
                                        statusText: $statusText, candidates: $candidates,
                                        scanNonce: $scanNonce, selectedPlayer: $selectedPlayer,
                                        blockAds: blockAds,
                                        stayOnSite: stayOnSite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !candidates.isEmpty || selectedPlayer != nil || isResolvingCapturedClip {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(showAllDetectedStreams ? "All detected streams" : "Captured video")
                                .font(.headline)
                            Spacer()
                            Button(showAllDetectedStreams
                                ? "Captured"
                                : "Other streams (\(candidates.count))") {
                                showAllDetectedStreams.toggle()
                            }
                            .font(.footnote.weight(.semibold))
                            .accessibilityLabel(showAllDetectedStreams
                                ? "Focus on currently playing video"
                                : "Show all \(candidates.count) detected streams")
                        }
                        .padding(.horizontal)
                        if !showAllDetectedStreams && isResolvingCapturedClip {
                            ProgressView("Finding this clip’s downloadable source…")
                                .font(.footnote).padding(.horizontal)
                        } else if !showAllDetectedStreams && displayedCandidates.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(captureIssue ?? "No single video player could be identified. Play one clip or enter PiP, then tap Capture Playing again.")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if let clipURL = selectedPlayer?.clipPageURL {
                                    Button("Open This Clip") { openSelectedClip(clipURL) }
                                        .font(.footnote.weight(.semibold))
                                }
                            }.padding(.horizontal)
                        }
                        ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(displayedCandidates) { candidate in
                                HStack(spacing: 8) {
                                    BrowserCandidateThumbnail(candidate: candidate)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(!showAllDetectedStreams ? "Selected player · source found" :
                                             candidate.isPlaying ? "Playing now · linked" :
                                             candidate.association == .possible ? "Possible playing video" :
                                             candidate.kind == .direct ? "Video candidate" :
                                             candidate.kind == .hls ? "HLS playlist" :
                                             candidate.kind == .dash ? "DASH manifest" : "Embedded player")
                                            .font(.subheadline.weight(.semibold))
                                        Text(candidate.url.host ?? "Media")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if candidate.association != .player &&
                                           (candidate.kind == .hls || candidate.kind == .direct) {
                                            Text("Unconfirmed · preview before saving")
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 2)
                                    VStack(spacing: 4) {
                                        if candidate.kind == .direct {
                                            Button("Save") { save(candidate) }
                                                .buttonStyle(.borderedProminent)
                                        } else if candidate.kind == .hls {
                                            Button("Save MP4") { saveHLSasMP4(candidate) }
                                                .buttonStyle(.borderedProminent)
                                            Button("Save Offline") { saveHLS(candidate) }
                                                .buttonStyle(.bordered)
                                        } else if candidate.kind == .embed {
                                            Button("Open Player") { openEmbedded(candidate) }
                                                .buttonStyle(.bordered)
                                        } else {
                                            Text("Stream detected").font(.caption)
                                        }
                                        if candidate.kind == .hls || candidate.kind == .direct {
                                            Button("Preview") {
                                                previewStream = BrowserMediaPreview(candidate: candidate)
                                            }
                                            .font(.caption)
                                        }
                                    }
                                    .font(.footnote)
                                }
                                Divider()
                            }
                        }.padding(.horizontal)
                        }
                        .frame(maxHeight: showAllDetectedStreams ? 360 : (displayedCandidates.isEmpty ? 1 : 170))
                    }
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
            .onChange(of: selectedPlayer) { selected in
                guard let selected else { return }
                // Cross-origin frames may report at slightly different times.
                // Don't resolve until the frame reporting has settled, and
                // don't proceed if a second active player makes it ambiguous.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    guard selectedPlayer == selected else { return }
                    await resolveCapturedPlayer(selected)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
        .sheet(isPresented: $showDownloads) {
            BrowserDownloadsSheet().environmentObject(library)
        }
        .sheet(item: $previewStream) { selection in
            BrowserSourcePreviewSheet(candidate: selection.candidate)
        }
    }

    private func navigateToAddress() {
        guard let webView else { return }
        do {
            let destination = try UniversalBrowserAddress.resolve(addressText)
            addressFocused = false
            scanNonce = nil
            candidates = []
            selectedPlayer = nil
            capturedCandidate = nil
            captureIssue = nil
            isResolvingCapturedClip = false
            showAllDetectedStreams = false
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
        statusText = "Locating the specific player that is playing or in PiP…"
        candidates = []
        selectedPlayer = nil
        capturedCandidate = nil
        captureIssue = nil
        isResolvingCapturedClip = false
        showAllDetectedStreams = false
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
                        ? "No stream candidates yet. Play a clip and retry Capture Playing."
                        : "Only the selected player's clip is shown by default; Other streams is an optional troubleshooting list."
                } catch {
                    statusText = error.localizedDescription
                }
            }
        }
    }

    /// The selected HTML5 element is the source of truth. RedGifs offers a
    /// stronger mapping: selected video element -> feed tile ID -> clip API.
    private func resolveCapturedPlayer(_ player: BrowserSelectedPlayer) async {
        guard selectedPlayer == player else { return }
        capturedCandidate = nil
        captureIssue = nil
        if let id = player.redGifsClipID {
            isResolvingCapturedClip = true
            defer {
                // A delayed response from an older clip must not leave the
                // loading indicator stuck or overwrite a newer capture.
                if selectedPlayer == player || selectedPlayer == nil {
                    isResolvingCapturedClip = false
                }
            }
            do {
                let candidate = try await RedGifsSelectedClipResolver().resolve(player)
                guard selectedPlayer == player else { return }
                capturedCandidate = candidate
                captureIssue = nil
                statusText = "Captured RedGifs clip \(id) from the actual player. Preview or Save; the browser stays open."
            } catch {
                guard selectedPlayer == player else { return }
                capturedCandidate = player.directCandidate
                captureIssue = player.directCandidate == nil
                    ? "The player was identified as RedGifs clip \(id), but its source could not be retrieved: \(error.localizedDescription). Open This Clip to use the dedicated page."
                    : nil
                if captureIssue != nil { statusText = "Source lookup unavailable for the captured clip." }
            }
            return
        }
        capturedCandidate = player.directCandidate
        captureIssue = player.directCandidate == nil
            ? "This player is identified, but it exposes a blob/MSE stream rather than a downloadable URL. PiP identifies the player, not its HLS manifest. Use the individual clip page or Other streams for manual inspection."
            : nil
        if capturedCandidate != nil {
            statusText = "Captured the exact \(player.isPiP ? "PiP" : "playing") video element. Preview or Save this stream."
        }
    }

    private func openSelectedClip(_ url: URL) {
        guard let webView, url.scheme?.lowercased() == "https",
              URLSafetyPolicy.isPublic(url) else { return }
        // A single tap replaces copying a clip URL to Notes; normal WebKit
        // back navigation remains available for the original feed.
        scanNonce = nil
        candidates = []
        selectedPlayer = nil
        capturedCandidate = nil
        captureIssue = nil
        showAllDetectedStreams = false
        statusText = "Opened the selected clip. Play it, then tap Capture Playing."
        approvedAddressNavigation = url
        webView.load(URLRequest(url: url))
    }

    private func saveHLSasMP4(_ candidate: UniversalWebMediaCandidate) {
        if library.queueBrowserHLSMP4(candidate) != nil {
            statusText = "MP4 conversion queued. The video source will be remuxed into a separate shareable file without altering the offline HLS package. Check Downloads for progress and Play / Review."
        } else {
            statusText = library.errorMessage ?? "Unable to queue MP4 conversion."
        }
    }

    private func saveHLS(_ candidate: UniversalWebMediaCandidate) {
        guard HLSOfflineDownloadService.supports(candidate) else {
            statusText = "This HLS playlist cannot be downloaded safely."
            return
        }
        if library.queueBrowserDownload(candidate, mode: .video) != nil {
            statusText = "HLS download queued. Keep browsing; use Downloads to check progress and review the saved video. This isn't an exportable MP4."
        } else {
            statusText = library.errorMessage ?? "Unable to queue this HLS stream."
        }
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
        if library.queueBrowserDownload(candidate, mode: mode) != nil {
            statusText = "Download queued. This page stays open—browse freely, and use Downloads to play or review the saved video."
        } else {
            statusText = library.errorMessage ?? "Unable to queue this video."
        }
    }
}

/// Browser previews stay inside a sheet; the underlying WKWebView and its scroll
/// position are retained. No video is downloaded merely to show the preview.
private struct BrowserMediaPreview: Identifiable {
    let candidate: UniversalWebMediaCandidate
    var id: String { candidate.id }
}

private struct BrowserSourcePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidate: UniversalWebMediaCandidate
    @State private var seek: Double?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Previewing the exact detected media URL, not another video from the feed.")
                        .font(.footnote).foregroundStyle(.secondary)
                    MediaPlayerView(url: candidate.url, kind: .video, seekRequest: $seek)
                    Text("If the preview cannot play, the site may require a browser session or this HLS stream may be unsupported. Use the exact short link when the source cannot be identified.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Stream Preview")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Back to Website") { dismiss() }
            } }
        }
    }
}

private struct BrowserCandidateThumbnail: View {
    let candidate: UniversalWebMediaCandidate
    @State private var generated: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.thinMaterial)
            if let poster = candidate.posterURL {
                AsyncImage(url: poster) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let generated {
                Image(uiImage: generated).resizable().scaledToFill()
            } else {
                Image(systemName: "play.rectangle")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 62, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel(candidate.posterURL != nil || generated != nil
                            ? "Source video thumbnail" : "Thumbnail unavailable")
        .task(id: candidate.id) {
            generated = nil
            guard candidate.posterURL == nil,
                  candidate.kind == .direct || candidate.kind == .hls else { return }
            // Apple's native generator supports regular file video and HLS
            // streams that provide compatible I-frame renditions. If the
            // source cannot supply a real frame, never invent a thumbnail.
            let asset = AVURLAsset(url: candidate.url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 124, height: 144)
            if let result = try? await generator.image(
                at: CMTime(seconds: 1, preferredTimescale: 600)),
               !Task.isCancelled {
                generated = UIImage(cgImage: result.image)
            }
        }
    }
}

private struct BrowserDownloadsSheet: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if library.browserDownloads.isEmpty {
                    Text("No downloads yet. Return to Website Browser, tap Find Video and select Save.")
                        .foregroundStyle(.secondary)
                }
                ForEach(library.browserDownloads) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.title).font(.headline).lineLimit(2)
                        Text(job.host).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            switch job.status {
                            case .queued:
                                Label("Queued", systemImage: "clock")
                            case .running:
                                ProgressView(value: job.progress).frame(maxWidth: .infinity)
                                Text("\(Int(job.progress * 100))%").monospacedDigit()
                            case .completed:
                                Label("Saved", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            case .failed:
                                Label("Failed", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.red)
                            case .canceled:
                                Text("Canceled").foregroundStyle(.secondary)
                            }
                            if job.status == .queued || job.status == .running {
                                Spacer(minLength: 0)
                                Button("Cancel", role: .destructive) {
                                    library.cancelBrowserDownload(job.id)
                                }.font(.caption)
                            }
                        }
                        .font(.caption)
                        if job.status == .completed, let itemID = job.savedItemID {
                            NavigationLink {
                                MediaReviewView(itemID: itemID)
                            } label: {
                                Label("Play / Review Saved Video", systemImage: "play.circle")
                            }
                        }
                        if let error = job.errorMessage {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }.padding(.vertical, 5)
                }
            }
            .navigationTitle("Downloads")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Back to Website") { dismiss() }
            } }
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
    @Binding var selectedPlayer: BrowserSelectedPlayer?
    let blockAds: Bool
    let stayOnSite: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(statusText: $statusText, pageURL: $pageURL,
                    approvedAddressNavigation: $approvedAddressNavigation,
                    candidates: $candidates, scanNonce: $scanNonce,
                    selectedPlayer: $selectedPlayer,
                    blockAds: blockAds, stayOnSite: stayOnSite)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsPictureInPictureMediaPlayback = true
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
        private let selectedPlayer: Binding<BrowserSelectedPlayer?>
        private var selectedPlayersByFrame: [String: BrowserSelectedPlayer] = [:]
        private var selectedPlayersNonce: String?
        private var blockerEnabled: Bool
        private var lockSiteEnabled: Bool
        private var blockerGeneration = 0

        init(statusText: Binding<String?>, pageURL: Binding<URL?>,
             approvedAddressNavigation: Binding<URL?>,
             candidates: Binding<[UniversalWebMediaCandidate]>,
             scanNonce: Binding<String?>,
             selectedPlayer: Binding<BrowserSelectedPlayer?>, blockAds: Bool,
             stayOnSite: Bool) {
            self.statusText = statusText
            self.pageURL = pageURL
            self.approvedAddressNavigation = approvedAddressNavigation
            self.candidates = candidates
            self.scanNonce = scanNonce
            self.selectedPlayer = selectedPlayer
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
                    if self.selectedPlayersNonce != expectedNonce {
                        self.selectedPlayersByFrame = [:]
                        self.selectedPlayersNonce = expectedNonce
                    }
                    let found = try UniversalMediaFrameResult.decodeSelectedPlayer(
                        json, frameURL: frameURL, expectedNonce: expectedNonce)
                    if let found {
                        self.selectedPlayersByFrame[frameURL.absoluteString] = found
                    } else {
                        self.selectedPlayersByFrame.removeValue(forKey: frameURL.absoluteString)
                    }
                    let selected = BrowserPlayerSelectionPolicy.single(
                        Array(self.selectedPlayersByFrame.values))
                    self.selectedPlayer.wrappedValue = selected
                    if selected == nil, !self.candidates.wrappedValue.isEmpty {
                        self.statusText.wrappedValue = "No unique playing/PiP player was identified. The diagnostic list is available under Other streams."
                    }
                } catch { /* Ignore malformed third-party frame messages. */ }
            }
        }

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            scanNonce.wrappedValue = nil
            candidates.wrappedValue = []
            selectedPlayer.wrappedValue = nil
            selectedPlayersByFrame = [:]
            selectedPlayersNonce = nil
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
