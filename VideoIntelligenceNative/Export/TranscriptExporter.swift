import Foundation
import UIKit

enum TranscriptExportFormat: String, CaseIterable, Identifiable {
    case txt, srt, json, pdf
    var id: String { rawValue }
}

struct TranscriptExporter {
    let storage: LibraryStorage

    func export(_ transcript: TranscriptRecord, format: TranscriptExportFormat) async throws -> URL {
        let directory = await storage.documentsURL.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = transcript.title.replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "-", options: .regularExpression)
        let url = directory.appendingPathComponent("\(safeTitle)-\(transcript.id).\(format.rawValue)")
        switch format {
        case .txt: try displayText(transcript).data(using: .utf8)?.write(to: url, options: .atomic)
        case .srt: try srt(transcript).data(using: .utf8)?.write(to: url, options: .atomic)
        case .json: try JSONEncoder.transcript.encode(transcript).write(to: url, options: .atomic)
        case .pdf: try await MainActor.run { try renderPDF(transcript, to: url) }
        }
        return url
    }

    func displayText(_ transcript: TranscriptRecord) -> String { transcript.correctedText ?? transcript.text }

    func srt(_ transcript: TranscriptRecord) -> String {
        transcript.segments.enumerated().map { index, segment in
            "\(index + 1)\n\(timecode(segment.start)) --> \(timecode(segment.end))\n\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n\n") + "\n"
    }

    func timecode(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d,%03d", milliseconds / 3_600_000, (milliseconds / 60_000) % 60, (milliseconds / 1_000) % 60, milliseconds % 1_000)
    }

    @MainActor
    private func renderPDF(_ transcript: TranscriptRecord, to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        try renderer.writePDF(to: url) { context in
            context.beginPage()
            var y: CGFloat = 54
            NSAttributedString(string: transcript.title, attributes: [.font: UIFont.systemFont(ofSize: 24, weight: .semibold)]).draw(in: CGRect(x: 54, y: y, width: 504, height: 50)); y += 58
            NSAttributedString(string: transcript.createdAt, attributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.secondaryLabel]).draw(in: CGRect(x: 54, y: y, width: 504, height: 18)); y += 30
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.label]
            for paragraph in displayText(transcript).components(separatedBy: "\n") {
                let text = NSAttributedString(string: paragraph.isEmpty ? " " : paragraph, attributes: attributes)
                let bounds = text.boundingRect(with: CGSize(width: 504, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                if y + bounds.height > 738 { context.beginPage(); y = 54 }
                text.draw(in: CGRect(x: 54, y: y, width: 504, height: bounds.height + 4)); y += bounds.height + 14
            }
        }
    }
}
