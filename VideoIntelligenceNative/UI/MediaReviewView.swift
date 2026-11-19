import SwiftUI
import Photos
import UIKit

struct MediaReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    let itemID: UUID
    @State private var transcript: TranscriptRecord?
    @State private var mediaURL: URL?
    @State private var seekRequest: Double?
    @State private var editing = false
    @State private var shareURL: URL?
    @State private var exportFile: MediaExportFile?
    @State private var savedToPhotos = false
    @State private var confirmDelete = false

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
                    if let mediaURL { MediaPlayerView(url: mediaURL, kind: item.kind, seekRequest: $seekRequest) }
                    else { Label("Source media was deleted; the transcript remains available.", systemImage: "doc.text").foregroundStyle(.secondary) }
                    actionPanel(item)
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
        .sheet(item: $exportFile, onDismiss: { cleanupExportFile() }) { entry in
            MediaFilePicker(url: entry.url)
        }
        .alert("Saved to Photos", isPresented: $savedToPhotos) { Button("OK", role: .cancel) {} } message: {
            Text("This video was added to your iPhone Photos library.")
        }
        .sheet(isPresented: $editing) { if let item, let transcript { TranscriptEditorView(item: item, initialText: transcript.correctedText ?? transcript.text) { text in self.transcript = try await library.saveCorrection(text, for: item) } } }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) { if let shareURL { ShareSheet(items: [shareURL]) } }
        .confirmationDialog("Delete this library item?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("Delete Item", role: .destructive) { if let item { Task { await library.deleteItem(item) } } }; Button("Cancel", role: .cancel) {} }
    }

    @ViewBuilder private func actionPanel(_ item: MediaLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
            Button { library.transcribe(item) } label: { Label(item.transcriptRelativePath == nil ? "Transcribe" : "Transcribe Again", systemImage: "waveform.badge.mic") }.buttonStyle(.borderedProminent).disabled(item.mediaRelativePath == nil || library.activeTaskID != nil)
            if library.activeTaskID == item.id { Button("Cancel", role: .destructive) { library.cancelOperation() } }
            }
            if item.mediaRelativePath != nil {
                HStack(spacing: 10) {
                    Button { exportMediaToFiles(item) } label: {
                        Label(item.kind == .video ? "Save Video to Files" : "Save Audio to Files", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    if item.kind == .video {
                        Button { saveVideoToPhotos(item) } label: {
                            Label("Save to Photos", systemImage: "photo.on.rectangle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .font(.subheadline)
            }
            Menu {
                if transcript != nil {
                    Button("Edit Transcript") { editing = true }
                    ForEach(TranscriptExportFormat.allCases) { format in Button("Export \(format.rawValue.uppercased())") { export(format, item: item) } }
                }
                if item.mediaRelativePath != nil {
                    Button("Share Media") { shareMedia(item) }
                    Button("Delete Media Only", role: .destructive) { Task { await library.deleteMedia(item); await reload() } }
                }
                Button("Delete Entire Item", role: .destructive) { confirmDelete = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }.buttonStyle(.bordered)
        }
    }

    private func reload() async {
        guard let item else { return }
        if let path = item.mediaRelativePath { mediaURL = try? await library.storage.URLFor(relativePath: path) }
        if item.transcriptRelativePath != nil { transcript = try? await library.transcript(for: item) }
    }

    private func exportMediaToFiles(_ item: MediaLibraryItem) {
        prepareMediaExport(item) { url in
            exportFile = MediaExportFile(url: url)
        }
    }

    private func shareMedia(_ item: MediaLibraryItem) {
        prepareMediaExport(item) { url in
            shareURL = url
        }
    }

    private func saveVideoToPhotos(_ item: MediaLibraryItem) {
        guard item.kind == .video, let path = item.mediaRelativePath else { return }
        Task {
            do {
                let localURL = try await library.storage.URLFor(relativePath: path)
                guard FileManager.default.fileExists(atPath: localURL.path) else { throw CocoaError(.fileNoSuchFile) }
                let permission = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard permission == .authorized || permission == .limited else {
                    library.errorMessage = "Photos access was denied. Enable Add Photos Only for Video Intelligence in iPhone Settings."
                    return
                }
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: localURL, options: nil)
                }
                savedToPhotos = true
            } catch {
                library.errorMessage = "Unable to save video to Photos: \(error.localizedDescription)"
            }
        }
    }

    private func cleanupExportFile() {
        if let url = exportFile?.url {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        exportFile = nil
    }

    private func prepareMediaExport(_ item: MediaLibraryItem, ready: @escaping @MainActor (URL) -> Void) {
        guard let relativePath = item.mediaRelativePath else { return }
        Task {
            do {
                let source = try await library.storage.URLFor(relativePath: relativePath)
                guard FileManager.default.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
                let cleanTitle = item.title
                    .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
                    .joined(separator: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let filename = String((cleanTitle.isEmpty ? "Exported Media" : cleanTitle).prefix(80))
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("VideoIntelligenceExport-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(filename)
                    .appendingPathExtension(source.pathExtension.isEmpty ? (item.kind == .video ? "mp4" : "m4a") : source.pathExtension)
                try FileManager.default.copyItem(at: source, to: destination)
                ready(destination)
            } catch {
                library.errorMessage = "Unable to export media: \(error.localizedDescription)"
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

private struct MediaExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MediaFilePicker: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
