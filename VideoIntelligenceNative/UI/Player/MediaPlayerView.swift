import AVFoundation
import AVKit
import Combine
import SwiftUI

/// Playback-only sessions already support AirPlay and Bluetooth A2DP.
/// Avoid .allowAirPlay/.allowBluetoothA2DP: Apple limits those explicit
/// options to playAndRecord and iOS can reject them with OSStatus -50.
enum MediaPlaybackAudioPolicy {
    static let category: AVAudioSession.Category = .playback
    static let mode: AVAudioSession.Mode = .moviePlayback
    static let options: AVAudioSession.CategoryOptions = []
}

@MainActor
final class MediaPlayerController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var scrubTime: Double = 0
    @Published var isScrubbing = false
    @Published var playbackRate: Float = 1
    @Published private(set) var errorMessage: String?

    let player: AVPlayer
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        configureAudioSession()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self, !self.isScrubbing else { return }
            self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
            self.scrubTime = self.currentTime
            let seconds = item.duration.seconds
            if seconds.isFinite { self.duration = max(0, seconds) }
            self.isPlaying = self.player.timeControlStatus == .playing
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.isPlaying = false; self?.currentTime = self?.duration ?? 0; self?.scrubTime = self?.duration ?? 0 }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in if item.status == .failed { self?.errorMessage = item.error?.localizedDescription ?? "Playback failed." } }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObservation?.invalidate()
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing { player.pause(); isPlaying = false }
        else { if currentTime >= duration, duration > 0 { seek(to: 0, resume: false) }; player.playImmediately(atRate: playbackRate); isPlaying = true }
    }

    func seek(to seconds: Double, resume: Bool = true) {
        let target = min(max(0, seconds), duration > 0 ? duration : seconds)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            Task { @MainActor in guard let self, completed else { return }; self.currentTime = target; self.scrubTime = target; if resume { self.player.playImmediately(atRate: self.playbackRate); self.isPlaying = true } }
        }
    }

    func skip(_ seconds: Double) { seek(to: currentTime + seconds, resume: isPlaying) }

    func finishScrubbing() { isScrubbing = false; seek(to: scrubTime, resume: isPlaying) }

    func setRate(_ rate: Float) { playbackRate = rate; if isPlaying { player.rate = rate } }

    func pause() { player.pause(); isPlaying = false }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(MediaPlaybackAudioPolicy.category,
                                    mode: MediaPlaybackAudioPolicy.mode,
                                    options: MediaPlaybackAudioPolicy.options)
            try session.setActive(true)
        } catch { errorMessage = "Audio output could not be activated: \(error.localizedDescription)" }
    }
}

struct MediaPlayerView: View {
    let kind: MediaKind
    @Binding var seekRequest: Double?
    @StateObject private var controller: MediaPlayerController

    init(url: URL, kind: MediaKind, seekRequest: Binding<Double?>) {
        self.kind = kind
        self._seekRequest = seekRequest
        self._controller = StateObject(wrappedValue: MediaPlayerController(url: url))
    }

    var body: some View {
        VStack(spacing: 12) {
            if kind == .video { PlayerControllerView(player: controller.player).frame(minHeight: 220).clipShape(RoundedRectangle(cornerRadius: 14)) }
            else { Image(systemName: "waveform.circle.fill").resizable().scaledToFit().frame(height: 100).foregroundStyle(.tint).padding() }
            Slider(value: $controller.scrubTime, in: 0...max(1, controller.duration), onEditingChanged: { editing in controller.isScrubbing = editing; if !editing { controller.finishScrubbing() } }).accessibilityLabel("Playback position")
            HStack { Text(Self.clock(controller.isScrubbing ? controller.scrubTime : controller.currentTime)); Spacer(); Text(Self.clock(controller.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Button { controller.skip(-15) } label: { Image(systemName: "gobackward.15") }.accessibilityLabel("Back 15 seconds")
                Button { controller.togglePlayback() } label: { Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 42)) }.accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                Button { controller.skip(15) } label: { Image(systemName: "goforward.15") }.accessibilityLabel("Forward 15 seconds")
                Menu("\(controller.playbackRate.formatted())×") { ForEach([0.5, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in Button("\(rate.formatted())×") { controller.setRate(Float(rate)) } } }
            }
            if let error = controller.errorMessage { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote) }
        }
        .onChange(of: seekRequest) { seconds in guard let seconds else { return }; controller.seek(to: seconds); seekRequest = nil }
        .onDisappear { controller.pause() }
    }

    static func clock(_ seconds: Double) -> String { String(format: "%02d:%02d", max(0, Int(seconds)) / 60, max(0, Int(seconds)) % 60) }
}

private struct PlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController { let controller = AVPlayerViewController(); controller.player = player; controller.showsPlaybackControls = true; return controller }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { if controller.player !== player { controller.player = player } }
}
