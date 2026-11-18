import SwiftUI
import UniformTypeIdentifiers

struct AudioImportView: View {
    @StateObject private var viewModel = AudioImportViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("Offline transcription foundation")
                    .font(.title2.weight(.semibold))

                Text("Choose one local audio file. Transcription is not enabled in this foundation build.")
                    .foregroundStyle(.secondary)

                statePanel

                Button {
                    viewModel.beginSelection()
                } label: {
                    Label("Choose Audio File", systemImage: "waveform.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose a local audio file")

                Spacer()
            }
            .padding()
            .navigationTitle("Video Intelligence")
            .fileImporter(
                isPresented: $viewModel.isImporterPresented,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false,
                onCompletion: viewModel.handleSelection
            )
            .onChange(of: viewModel.isImporterPresented) { isPresented in
                if !isPresented {
                    viewModel.importerDismissed()
                }
            }
        }
    }

    @ViewBuilder
    private var statePanel: some View {
        switch viewModel.state {
        case .idle:
            statusCard(icon: "tray", title: "No file selected", detail: "Audio stays on this device.")
        case .selecting:
            statusCard(icon: "folder", title: "Selecting audio", detail: "Choose a file from the system picker.")
        case .selected(let file):
            VStack(alignment: .leading, spacing: 12) {
                statusCard(icon: "checkmark.circle.fill", title: "Audio selected", detail: file.displayName)
                Button("Remove Selection", role: .destructive, action: viewModel.clearSelection)
                    .accessibilityLabel("Remove selected audio file")
            }
        case .failure(let message):
            statusCard(icon: "exclamationmark.triangle.fill", title: "Import failed", detail: message)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Audio import failed. \(message)")
        }
    }

    private func statusCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    AudioImportView()
}
