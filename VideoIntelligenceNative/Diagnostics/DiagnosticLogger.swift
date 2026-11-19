import Foundation

struct DiagnosticEvent: Codable, Sendable {
    let timestamp: Date
    let stage: String
    let message: String
    let errorDomain: String?
    let errorCode: Int?
    let underlyingCause: String?
    let retryAttempt: Int
}

actor DiagnosticLogger {
    private let fileURL: URL

    init(applicationSupportURL: URL) {
        fileURL = applicationSupportURL.appendingPathComponent("diagnostics.jsonl")
    }

    func record(stage: String, message: String, error: Error? = nil, retryAttempt: Int = 0) {
        let nsError = error as NSError?
        let underlying = nsError?.userInfo[NSUnderlyingErrorKey] as? NSError
        let event = DiagnosticEvent(timestamp: Date(), stage: stage, message: message, errorDomain: nsError?.domain, errorCode: nsError?.code, underlyingCause: underlying?.localizedDescription, retryAttempt: retryAttempt)
        guard let data = try? JSONEncoder.library.encode(event) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) { FileManager.default.createFile(atPath: fileURL.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data([0x0A]))
    }

    func exportURL() -> URL? { FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil }
}
