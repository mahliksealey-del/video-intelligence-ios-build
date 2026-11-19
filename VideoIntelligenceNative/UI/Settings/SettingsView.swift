import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Offline transcription model") {
                    switch library.modelManager.state {
                    case .notDownloaded: Button("Download base.en") { Task { await library.modelManager.download() } }
                    case .downloading(let progress): ProgressView("Downloading base.en…", value: progress); Button("Keep App Open During Download") {}.disabled(true)
                    case .ready: Label("base.en is ready for offline transcription", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed(let message): Text(message).foregroundStyle(.red); Button("Try Download Again") { Task { await library.modelManager.download() } }
                    }
                    Text("Model weights are downloaded only with your action, stored in Application Support, and excluded from device backup where supported.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Storage") {
                    LabeledContent("App storage", value: ByteCountFormatter.string(fromByteCount: library.storageBytes, countStyle: .file))
                    Button("Clear Regenerable Caches") { Task { await library.clearCaches() } }
                    Text("Media: Files → On My iPhone → Video Intelligence. Models and the private library index stay in app-managed storage.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Engine") { LabeledContent("WhisperKit", value: "1.1.1"); LabeledContent("Initial model", value: "base.en") }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
