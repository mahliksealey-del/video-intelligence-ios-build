import AVKit
import SwiftUI

struct MediaPlayerView: View {
    let url: URL
    let kind: MediaKind
    @Binding var seekRequest: Double?
    @State private var player: AVPlayer

    init(url: URL, kind: MediaKind, seekRequest: Binding<Double?>) {
        self.url = url
        self.kind = kind
        self._seekRequest = seekRequest
        self._player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VStack(spacing: 10) {
            if kind == .video { VideoPlayer(player: player).frame(minHeight: 210).clipShape(RoundedRectangle(cornerRadius: 14)) }
            else { Image(systemName: "waveform.circle.fill").resizable().scaledToFit().frame(height: 110).foregroundStyle(.tint).padding() }
            HStack {
                Button { player.play() } label: { Label("Play", systemImage: "play.fill") }
                Button { player.pause() } label: { Label("Pause", systemImage: "pause.fill") }
            }.buttonStyle(.bordered)
        }
        .onChange(of: seekRequest) { seconds in guard let seconds else { return }; player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)); player.play(); seekRequest = nil }
        .onDisappear { player.pause() }
    }
}
