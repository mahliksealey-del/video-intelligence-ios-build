import SwiftUI

struct TranscriptEditorView: View {
    let item: MediaLibraryItem
    let initialText: String
    let onSave: (String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var error: String?

    init(item: MediaLibraryItem, initialText: String, onSave: @escaping (String) async throws -> Void) {
        self.item = item; self.initialText = initialText; self.onSave = onSave; self._text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text).font(.body).lineSpacing(5).padding().navigationTitle("Edit Transcript")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { do { try await onSave(text); dismiss() } catch { self.error = error.localizedDescription } } } }
                }
                .alert("Could Not Save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
        }
    }
}
