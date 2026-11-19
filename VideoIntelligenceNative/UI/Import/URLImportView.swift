import SwiftUI

struct URLImportView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var sourceURL: URL?
    @State private var formats: [SocialFormatOption] = []
    @State private var resolved: ResolvedSocialMedia?
    @State private var isResolving = false
    @State private var resolveStartedAt: Date?
    @State private var errorMessage: String?

    private var provider: MediaProvider? { (try? MediaURLValidator.validate(value)).map(MediaProvider.detect) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Media URL") {
                    TextField("YouTube, TikTok, Instagram, or direct media URL", text: $value).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled()
                    if let provider { LabeledContent("Detected", value: provider.rawValue) }
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
                if let resolved {
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
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
                Section { Text("Extraction and transfer run locally. Private, DRM-protected, unavailable, or authentication-gated media is not bypassed. Download only media you are authorized to save.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("Get Media")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(provider == .direct ? "Download" : "Resolve") { resolve() }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving || library.socialDownloadProgress != nil) }
            }
        }
    }

    private func resolve() {
        errorMessage = nil; formats = []; resolved = nil
        guard provider != .direct else { library.importURL(value); dismiss(); return }
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
