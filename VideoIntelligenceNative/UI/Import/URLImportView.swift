import SwiftUI

struct URLImportView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Direct media URL") { TextField("https://example.com/media.mp4", text: $value).textInputAutocapitalization(.never).keyboardType(.URL).autocorrectionDisabled() }
                Section { Text("Supports accessible HTTP(S) audio and video files. Web pages, authenticated links, streaming manifests, and DRM media are not downloaded.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Download Media")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Download") { library.importURL(value); dismiss() }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
}
