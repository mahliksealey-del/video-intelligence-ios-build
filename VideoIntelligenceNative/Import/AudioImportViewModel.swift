import Combine
import Foundation

@MainActor
final class AudioImportViewModel: ObservableObject {
    @Published private(set) var state: AudioImportState = .idle
    @Published var isImporterPresented = false

    func beginSelection() {
        state = .selecting
        isImporterPresented = true
    }

    func importerDismissed() {
        if case .selecting = state {
            state = .idle
        }
    }

    func handleSelection(_ result: Result<[URL], Error>) {
        isImporterPresented = false

        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                state = .failure(message: "No audio file was selected. Please choose a local audio file and try again.")
                return
            }
            state = .selected(ImportedAudioFile(url: url))
        case .failure(let error):
            if (error as? CocoaError)?.code == .userCancelled {
                state = .idle
            } else {
                state = .failure(message: "The audio file could not be opened. \(error.localizedDescription)")
            }
        }
    }

    func clearSelection() {
        state = .idle
    }
}
