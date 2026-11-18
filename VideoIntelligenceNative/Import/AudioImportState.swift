import Foundation

enum AudioImportState: Equatable {
    case idle
    case selecting
    case selected(ImportedAudioFile)
    case failure(message: String)
}

struct ImportedAudioFile: Equatable {
    let url: URL

    var displayName: String {
        url.lastPathComponent
    }
}
