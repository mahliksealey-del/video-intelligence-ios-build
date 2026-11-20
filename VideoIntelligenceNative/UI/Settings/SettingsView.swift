import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var deleteModel: InstalledModel?

    var body: some View {
        NavigationStack {
            Form {
                Section("Transcription profile") {
                    Picker("Profile", selection: Binding(get: { library.modelManager.selectedProfile }, set: { library.modelManager.selectedProfile = $0 })) { ForEach(TranscriptionProfile.allCases) { Text($0.title).tag($0) } }
                    Text(library.modelManager.selectedProfile.detail).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Speech models") {
                    ForEach(Array(Set(TranscriptionProfile.allCases.map(\.model))).sorted(), id: \.self) { name in
                        ModelDownloadRow(name: name, manager: library.modelManager) { deleteModel = $0 }
                    }
                    Text("Models download only with your action, remain in private Application Support, and are excluded from backup when supported.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Storage") {
                    LabeledContent("App storage", value: ByteCountFormatter.string(fromByteCount: library.storageBytes, countStyle: .file))
                    Button("Clear Regenerable Caches") { Task { await library.clearCaches() } }
                    Text("Media remains in Files → On My iPhone → Video Intelligence. Clearing caches does not delete media, transcripts, or validated models.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Diagnostics") {
                    Button("Export Diagnostics") { Task { shareURL = await library.modelManager.diagnosticsURL() } }
                    Text("The local diagnostic log records stage, time, error domain/code, underlying cause, and retry count. It excludes media, transcripts, cookies, and URLs.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Engine") { LabeledContent("WhisperKit", value: "1.1.1"); LabeledContent("Pinned revision", value: "1bbc57c…") }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) { if let shareURL { ShareSheet(items: [shareURL]) } }
            .confirmationDialog("Delete \(deleteModel?.name ?? "model")?", isPresented: Binding(get: { deleteModel != nil }, set: { if !$0 { deleteModel = nil } }), titleVisibility: .visible) {
                Button("Delete Model", role: .destructive) { if let model = deleteModel { Task { try? await library.modelManager.delete(model.name); deleteModel = nil } } }
                Button("Cancel", role: .cancel) { deleteModel = nil }
            }
        }
    }

}

private struct ModelDownloadRow: View {
    let name: String
    @ObservedObject var manager: WhisperModelManager
    let requestDelete: (InstalledModel) -> Void

    var body: some View {
        let model = manager.models[name]
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(name).font(.headline); Spacer(); if let model, model.bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) } }
            switch model?.state ?? .unavailable {
            case .unavailable:
                Button("Download") { manager.download(name) }
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text(progress > 0 ? "Downloading… \(Int(progress * 100))%" : "Preparing model download…")
                }
                if let startedAt = manager.downloadStartedAt[name] {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                        if elapsed >= 5, progress > 0.08, progress < 0.98 {
                            let remaining = min(86_400, elapsed * (1 - progress) / progress)
                            Text("Elapsed \(MediaPlayerView.clock(elapsed)) · ~\(MediaPlayerView.clock(remaining)) left (approximate model ETA)")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Elapsed \(MediaPlayerView.clock(elapsed)) · estimating model download time…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Cancel Download", role: .cancel) { manager.cancelDownload() }
            case .downloaded:
                ProgressView("Validating…")
            case .validated:
                HStack { Label("Validated", systemImage: "checkmark.seal.fill").foregroundStyle(.green); Spacer(); if let model { Button("Delete", role: .destructive) { requestDelete(model) } } }
            case .loaded:
                Label("Loaded", systemImage: "memorychip.fill").foregroundStyle(.green)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.red)
                Button("Retry") { manager.download(name) }
            }
        }.padding(.vertical, 4)
    }
}
