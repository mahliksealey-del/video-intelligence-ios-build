import SwiftUI

struct MediaReviewView: View {
    @EnvironmentObject private var library: LibraryStore
    let itemID: UUID
    @State private var transcript: TranscriptRecord?
    @State private var mediaURL: URL?
    @State private var seekRequest: Double?
    @State private var editing = false
    @State private var shareURL: URL?
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
                    if let transcript { Divider(); TranscriptReaderView(transcript: transcript) { seekRequest = $0 } }
                    else if item.status == .transcribing || item.status == .extractingAudio {
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
                }.padding()
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .sheet(isPresented: $editing) { if let item, let transcript { TranscriptEditorView(item: item, initialText: transcript.correctedText ?? transcript.text) { text in self.transcript = try await library.saveCorrection(text, for: item) } } }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) { if let shareURL { ShareSheet(items: [shareURL]) } }
        .confirmationDialog("Delete this library item?", isPresented: $confirmDelete, titleVisibility: .visible) { Button("Delete Item", role: .destructive) { if let item { Task { await library.deleteItem(item) } } }; Button("Cancel", role: .cancel) {} }
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
                    Button("Export Media") { exportMedia(item) }
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

    private func exportMedia(_ item: MediaLibraryItem) {
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
                shareURL = destination
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
