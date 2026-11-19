import SwiftUI

struct TranscriptReaderView: View {
    let transcript: TranscriptRecord
    let onSeek: (Double) -> Void
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Search transcript", text: $search).textFieldStyle(.roundedBorder)
            Text(transcript.title).font(.title2.weight(.semibold))
            Text(transcript.createdAt).font(.caption).foregroundStyle(.secondary)
            if transcript.correctedText != nil {
                Text(transcript.correctedText ?? "").textSelection(.enabled).font(.body).lineSpacing(6)
            } else {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { _, segment in
                    if search.isEmpty || segment.text.localizedCaseInsensitiveContains(search) {
                        VStack(alignment: .leading, spacing: 5) {
                            Button(Self.timestamp(segment.start)) { onSeek(segment.start) }.font(.caption.monospacedDigit()).foregroundStyle(.tint)
                            Text(segment.text).textSelection(.enabled).lineSpacing(5)
                        }
                    }
                }
            }
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
