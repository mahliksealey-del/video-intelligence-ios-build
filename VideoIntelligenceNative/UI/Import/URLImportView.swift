import SwiftUI

struct URLImportView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var instagramSession = InstagramSession.shared
    @State private var showingInstagramSignIn = false
    @State private var value = ""
    @State private var sourceURL: URL?
    @State private var formats: [SocialFormatOption] = []
    @State private var resolved: ResolvedSocialMedia?
    @State private var isResolving = false
    @State private var resolveStartedAt: Date?
    @State private var errorMessage: String?
    @State private var showTikTokBrowser = false
    @State private var tikTokMode: SocialDownloadMode = .video

    private var provider: MediaProvider? { (try? MediaURLValidator.validate(value)).map(MediaProvider.detect) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Media URL") {
                    TextField("YouTube, TikTok, Instagram, or direct media URL", text: $value).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    if let provider { LabeledContent("Detected", value: provider.rawValue) }
                }
                if provider == .tiktok && resolved == nil {
                    Section("TikTok download") {
                        Picker("Save as", selection: $tikTokMode) {
                            ForEach(SocialDownloadMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        Text("TikTok opens in the app's browser so the video can load with its existing session. Play it, then tap Download.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if provider == .instagram {
                    Section("Instagram account") {
                        if instagramSession.hasSession {
                            Label("Instagram session available on this iPhone", systemImage: "checkmark.shield.fill")
                            Button("Sign out of Instagram", role: .destructive) { Task { await instagramSession.signOut() } }
                        } else {
                            Text("Public Reels can still require an Instagram session.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Button(instagramSession.hasSession ? "Update Instagram Sign-In" : "Sign in to Instagram") {
                            showingInstagramSignIn = true
                        }
                    }
                }
                if isResolving {
                    Section {
                        ProgressView("Resolving on this iPhone…")
                        if let startedAt = resolveStartedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                                Text("Checking provider · elapsed \(MediaPlayerView.clock(elapsed)) · time remaining unknown")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !formats.isEmpty {
                    Section("Available video formats") {
                        ForEach(formats) { option in
                            Button { choose(option) } label: {
                                HStack { Text("\(option.height)p · \(option.codecLabel)"); Spacer(); if let bytes = option.approximateBytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).foregroundStyle(.secondary) } }
                            }
                        }
                    }
                }
                if let resolved, library.socialDownloadProgress == nil {
                    Section("Ready") {
                        Text(resolved.title).font(.headline)
                        Button("Download Video") { start(resolved, mode: .video) }
                        Button("Download Audio") { start(resolved, mode: .audio) }
                        Button("Download & Transcribe") { start(resolved, mode: .transcribe) }
                    }
                }
                if let progress = library.socialDownloadProgress {
                    Section("Downloading") {
                        ProgressView(value: progress)
                        if let startedAt = library.socialDownloadStartedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                                if progress >= 0.98 {
                                    Text("Finalizing media · elapsed \(MediaPlayerView.clock(elapsed))").font(.caption).foregroundStyle(.secondary)
                                } else if elapsed >= 5, progress > 0.08 {
                                    let remaining = min(86_400, elapsed * (1 - progress) / progress)
                                    Text("Elapsed \(MediaPlayerView.clock(elapsed)) · ~\(MediaPlayerView.clock(remaining)) left (approximate transfer ETA)")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Elapsed \(MediaPlayerView.clock(elapsed)) · estimating transfer time…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("Cancel", role: .destructive) { library.cancelOperation() }
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)

                    }
                }
                Section { Text("Extraction and transfer run locally. Private, DRM-protected, unavailable, or authentication-gated media is not bypassed. Download only media you are authorized to save.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Get Media")
            .sheet(isPresented: $showTikTokBrowser) {
                if let url = try? MediaURLValidator.validate(value), MediaProvider.detect(url) == .tiktok {
                    TikTokBrowserFallbackView(url: url) { media in
                        sourceURL = url
                        formats = []
                        resolved = nil
                        errorMessage = nil
                        // User explicitly selected the download mode and tapped
                        // Download in the visible TikTok browser.
                        library.downloadSocial(media, sourceURL: url, mode: tikTokMode)
                    }
                }
            }
            .task { await instagramSession.refresh() }
            .sheet(isPresented: $showingInstagramSignIn, onDismiss: { Task { await instagramSession.refresh() } }) {
                InstagramSignInView(session: instagramSession)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(provider == .direct ? "Download" : provider == .tiktok ? "Open TikTok" : "Resolve") { resolve() }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving || library.socialDownloadProgress != nil) }
            }
        }
    }

    private func resolve() {
        errorMessage = nil; formats = []; resolved = nil
        switch MediaResolutionRoute.forProvider(provider) {
        case .direct:
            library.importURL(value)
            dismiss()
            return
        case .browser:
            do {
                // The user-tested TikTok browser method is the primary route.
                // Skip the Python webpage call that consistently displays an error.
                sourceURL = try MediaURLValidator.validate(value)
                showTikTokBrowser = true
            } catch {
                errorMessage = error.localizedDescription
            }
            return
        case .extractor:
            break
        }
        isResolving = true
        resolveStartedAt = Date()
        Task {
            do {
                let (url, listing) = try await library.listSocialFormats(value)
                sourceURL = url
                switch listing { case .ready(let media): resolved = media; case .choices(let options): formats = options }
            } catch { errorMessage = error.localizedDescription }
            isResolving = false
            resolveStartedAt = nil
        }
    }

    private func choose(_ option: SocialFormatOption) {
        guard let sourceURL else { return }
        isResolving = true; errorMessage = nil; resolveStartedAt = Date()
        Task { do { resolved = try await library.resolveSocial(sourceURL, option: option); formats = [] } catch { errorMessage = error.localizedDescription }; isResolving = false; resolveStartedAt = nil }
    }

    private func start(_ media: ResolvedSocialMedia, mode: SocialDownloadMode) {
        guard let sourceURL else { return }
        library.downloadSocial(media, sourceURL: sourceURL, mode: mode)
    }
}
