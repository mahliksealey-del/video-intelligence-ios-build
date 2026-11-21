import AVFoundation
import SwiftUI
import UIKit

struct MediaReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    let itemID: UUID
    @State private var transcript: TranscriptRecord?
    @State private var mediaURL: URL?
    @State private var seekRequest: Double?
    @State private var editing = false
    @State private var shareURL: URL?
    @State private var confirmDelete = false
    @State private var isExportingMedia = false
    @State private var exportProgress: Double = 0
    @State private var exportErrorMessage: String?

    private var item: MediaLibraryItem? { library.items.first { $0.id == itemID } }

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.title.weight(.bold))
                        Text("\(item.kind.rawValue.capitalized) · \(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond)))").foregroundStyle(.secondary)
                        if let timing = item.lastPerformance {
                            Text("\(timing.wasWarm ? "Warm" : "Cold") \(item.status == .transcribed ? "transcription" : "run") · load \(timing.modelInitializationSeconds.formatted(.number.precision(.fractionLength(2))))s · inference \(timing.inferenceSeconds.formatted(.number.precision(.fractionLength(2))))s · total \(timing.totalSeconds.formatted(.number.precision(.fractionLength(2))))s").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let mediaURL {
                        MediaPlayerView(url: mediaURL, kind: item.kind, seekRequest: $seekRequest)
                    } else if item.mediaRelativePath == nil {
                        Label("The original media was removed from this library entry. Its transcript, if any, is retained.", systemImage: "doc.text")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Saved media is currently unavailable", systemImage: "externaldrive.badge.questionmark")
                                .foregroundStyle(.orange)
                            Text(item.sourceFilename.lowercased().hasSuffix(".movpkg")
                                 ? "The HLS package could not be found at its expected location. iOS may have moved or cleared it. This does not prove that you deleted it, and this app has not deleted the library entry."
                                 : "The saved file could not be found. Keep the library entry and check for an existing copy in Files before removing anything.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    actionPanel(item)
                    if isExportingMedia {
                        ProgressView(value: exportProgress) {
                            Text("Preparing shareable MP4… \(Int(exportProgress * 100))%")
                        }
                    }
                    if item.status == .transcribing || item.status == .extractingAudio {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(item.status == .extractingAudio ? "Extracting audio…" : "Transcribing on this iPhone…")
                            if library.activeTaskID == item.id, let startedAt = library.activeTaskStartedAt {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                                    if let expected = library.estimatedTranscriptionSeconds(for: item) {
                                        let remaining = expected - elapsed
                                        Text(remaining > 0
                                            ? "Elapsed \(MediaPlayerView.clock(elapsed)) · ~\(MediaPlayerView.clock(remaining)) left (calibrated estimate)"
                                            : "Elapsed \(MediaPlayerView.clock(elapsed)) · running longer than previous estimate")
                                            .font(.caption).foregroundStyle(.secondary)
                                    } else {
                                        Text("Elapsed \(MediaPlayerView.clock(elapsed)) · calibrating from first completed transcription")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    if let transcript { Divider(); TranscriptReaderView(transcript: transcript) { seekRequest = $0 } }
                }.padding()
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .sheet(isPresented: $editing) { if let item, let transcript { TranscriptEditorView(item: item, initialText: transcript.correctedText ?? transcript.text) { text in self.transcript = try await library.saveCorrection(text, for: item) } } }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) { if let shareURL { ShareSheet(items: [shareURL]) } }
        .confirmationDialog("Delete this library item?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("Delete Item", role: .destructive) { if let item { Task { await library.deleteItem(item) } } }; Button("Cancel", role: .cancel) {} }
        .alert("Media Export", isPresented: Binding(
            get: { exportErrorMessage != nil },
            set: { if !$0 { exportErrorMessage = nil } })) {
            Button("OK") { exportErrorMessage = nil }
        } message: { Text(exportErrorMessage ?? "") }
    }

    @ViewBuilder private func actionPanel(_ item: MediaLibraryItem) -> some View {
        HStack {
            Button { library.transcribe(item) } label: { Label(item.transcriptRelativePath == nil ? "Transcribe" : "Transcribe Again", systemImage: "waveform.badge.mic") }.buttonStyle(.borderedProminent).disabled(item.mediaRelativePath == nil || library.activeTaskID != nil)
            if library.activeTaskID == item.id { Button("Cancel", role: .destructive) { library.cancelOperation() } }
            Menu {
                if transcript != nil {
                    Button("Edit Transcript") { editing = true }
                    ForEach(TranscriptExportFormat.allCases) { format in Button("Export \(format.rawValue.uppercased())") { export(format, item: item) } }
                }
                if item.mediaRelativePath != nil {
                    if item.sourceFilename.lowercased().hasSuffix(".movpkg") {
                        Button(item.hlsPlaylistURL == nil
                               ? "Try Convert Offline HLS to MP4"
                               : "Export HLS Source as MP4") { exportMedia(item) }
                            .disabled(isExportingMedia || mediaURL == nil)
                        Text("Apple-managed HLS packages might not be exportable. If conversion fails, try a direct MP4 from the source page.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Export Media") { exportMedia(item) }
                            .disabled(isExportingMedia || mediaURL == nil)
                    }
                    if let sourcePage = shareableSourcePage(for: item) {
                        Button("Copy Original Page Link") {
                            UIPasteboard.general.string = sourcePage.absoluteString
                            exportErrorMessage = "Original webpage link copied. Open Video Intelligence Website Browser, paste the address, and use Get Video to look for a direct MP4 copy. Your offline HLS file is unchanged."
                        }
                    }
                    Button("Delete Media Only", role: .destructive) { Task { await library.deleteMedia(item); await reload() } }
                }
                Button("Delete Entire Item", role: .destructive) { confirmDelete = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }.buttonStyle(.bordered)
        }
    }

    private func shareableSourcePage(for item: MediaLibraryItem) -> URL? {
        guard let value = item.sourceURL,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              URLSafetyPolicy.isPublic(url),
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func reload() async {
        guard let item else { return }
        mediaURL = nil
        if let path = item.mediaRelativePath,
           let resolved = try? await library.storage.URLFor(relativePath: path),
           FileManager.default.fileExists(atPath: resolved.path) {
            mediaURL = resolved
        }
        if item.transcriptRelativePath != nil { transcript = try? await library.transcript(for: item) }
    }

    private enum HLSExportError: LocalizedError {
        case unsupported

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "This system-managed HLS package cannot be converted into MP4 with Apple's export APIs. It may use a protected or non-exportable format. The original package has NOT been removed. For an exportable copy, use Get Video and choose the direct MP4 source when the website offers one."
            }
        }
    }

    private func exportOfflineHLS(from packageURL: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: packageURL)
        guard try await asset.load(.isPlayable) else {
            throw HLSExportError.unsupported
        }
        // A movpkg is an offline streaming package, not a disguised MP4.
        // AVFoundation may export *some* unprotected packages, but it will
        // reject DRM/non-exportable HLS. Never decrypt content or relocate
        // Apple's original package.
        let presets = [AVAssetExportPresetHighestQuality, AVAssetExportPresetPassthrough]
        var export: AVAssetExportSession?
        for preset in presets {
            if let session = AVAssetExportSession(asset: asset, presetName: preset),
               session.supportedFileTypes.contains(.mp4) {
                export = session
                break
            }
        }
        guard let export else { throw HLSExportError.unsupported }
        export.outputURL = destination
        export.outputFileType = .mp4
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                export.exportAsynchronously { continuation.resume() }
            }
        } onCancel: { export.cancelExport() }
        guard export.status == .completed,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw export.error ?? HLSExportError.unsupported
        }
    }

    private func exportMedia(_ item: MediaLibraryItem) {
        guard let relativePath = item.mediaRelativePath, !isExportingMedia else { return }
        isExportingMedia = true
        exportProgress = 0
        Task {
            defer { isExportingMedia = false }
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("VideoIntelligenceExport-\(UUID().uuidString)", isDirectory: true)
            do {
                let source = try await library.storage.URLFor(relativePath: relativePath)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let cleanTitle = item.title
                    .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
                    .joined(separator: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let filename = String((cleanTitle.isEmpty ? "Exported Media" : cleanTitle).prefix(80))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let isHLS = source.pathExtension.lowercased() == "movpkg"
                let ext = isHLS ? "mp4" : (source.pathExtension.isEmpty
                    ? (item.kind == .video ? "mp4" : "m4a") : source.pathExtension)
                let destination = folder.appendingPathComponent(filename)
                    .appendingPathExtension(ext)
                if isHLS, let original = item.hlsPlaylistURL,
                   let playlist = URL(string: original),
                   let page = shareableSourcePage(for: item) {
                    // New HLS saves remember their selected playlist. Re-fetch
                    // and remux the original clear VOD stream, never the
                    // system-managed offline .movpkg package.
                    let candidate = UniversalWebMediaCandidate(
                        url: playlist, pageURL: page,
                        title: item.title, userAgent: nil,
                        kind: .hls, isPlaying: false)
                    let converted = try await HLSMP4ConversionService().convert(candidate) { value in
                        Task { @MainActor in exportProgress = value }
                    }
                    defer { try? FileManager.default.removeItem(at: converted) }
                    try FileManager.default.copyItem(at: converted, to: destination)
                } else if isHLS {
                    // Legacy HLS library entries did not record their source
                    // manifest. Preserve Apple's existing best-effort export.
                    try await exportOfflineHLS(from: source, to: destination)
                } else {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
                exportProgress = 1
                shareURL = destination
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if item.sourceFilename.lowercased().hasSuffix(".movpkg") {
                    exportErrorMessage = "HLS MP4 conversion failed (\(error.localizedDescription)). Your offline file was not altered. If this older entry lacks its original playlist URL, open the source page, play the clip, tap Get Video, then Save MP4 to make a separate file."
                } else {
                    exportErrorMessage = "Unable to export media: \(error.localizedDescription)"
                }
            }
        }
    }

    private func export(_ format: TranscriptExportFormat, item: MediaLibraryItem) {
        guard let transcript else { return }
        Task { do { shareURL = try await TranscriptExporter(storage: library.storage).export(transcript, format: format) } catch { library.errorMessage = error.localizedDescription } }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
