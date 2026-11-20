import AVFoundation
import Foundation
import WebKit

enum SocialDownloadMode: String, CaseIterable, Identifiable, Sendable {
    case video = "Download Video"
    case audio = "Download Audio"
    case transcribe = "Download & Transcribe"
    var id: String { rawValue }
}

struct SocialDownloadResult: Sendable {
    let fileURL: URL
    let title: String
    let sourceURL: URL
    let shouldTranscribe: Bool
}

final class TrackDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    private var session: URLSession?
    private var usesTikTokBrowser = false

    func download(_ track: SocialMediaTrack, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        self.progress = progress
        self.usesTikTokBrowser = track.useBrowserCookies
        var request = URLRequest(url: track.url)
        track.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        if track.useBrowserCookies {
            // The TikTok WKWebView may have passed the provider's public
            // challenge/consent page. Carry only that site's cookies into this
            // isolated URLSession, with ordinary RFC domain/path matching.
            // Never use the browser cookie store on YouTube/Instagram requests.
            let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            for cookie in all where Self.isTikTokCookieDomain(cookie.domain) {
                configuration.httpCookieStorage?.setCookie(cookie)
            }
            configuration.httpCookieAcceptPolicy = .always
            configuration.httpShouldSetCookies = true
        }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: { session.invalidateAndCancel() }
    }

    static func isTikTokCookieDomain(_ value: String) -> Bool {
        let host = value.lowercased().hasPrefix(".") ? String(value.lowercased().dropFirst()) : value.lowercased()
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
            || host == "tiktokcdn.com" || host.hasSuffix(".tiktokcdn.com")
            || host == "tiktokcdn-eu.com" || host.hasSuffix(".tiktokcdn-eu.com")
            || host == "tiktokcdn-us.com" || host.hasSuffix(".tiktokcdn-us.com")
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, let finalURL = response.url,
              URLSafetyPolicy.isPublic(finalURL) else {
            continuation?.resume(throwing: MediaDownloadError.unsupportedContent)
            continuation = nil
            return
        }
        if !(200...299).contains(response.statusCode) {
            let error: Error = usesTikTokBrowser
                ? SocialExtractionError.unsupported("TikTok's media endpoint returned HTTP \(response.statusCode) to the iPhone download request.")
                : MediaDownloadError.unsupportedContent
            continuation?.resume(throwing: error)
            continuation = nil
            return
        }
        let mime = (response.mimeType ?? "").lowercased()
        if usesTikTokBrowser && (mime.contains("text/html") || mime.contains("application/json") || mime.contains("text/plain")) {
            continuation?.resume(throwing: SocialExtractionError.unsupported(
                "TikTok sent \(mime) instead of video (HTTP \(response.statusCode)); browser playback alone does not grant a separate download."))
            continuation = nil
            return
        }
        do {
            let size = Int64((try location.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            guard size > 0, size <= MediaDownloader.maximumBytes else { throw size == 0 ? MediaDownloadError.unsupportedContent : MediaDownloadError.tooLarge }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(finalURL.pathExtension.isEmpty ? "bin" : finalURL.pathExtension)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch { continuation?.resume(throwing: error) }
        continuation = nil
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress?(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, continuation != nil { continuation?.resume(throwing: error); continuation = nil }
        session.finishTasksAndInvalidate()
    }
}

struct SocialMediaMerger {
    func merge(video: URL, audio: URL, output: URL) async throws {
        let folder = output.deletingLastPathComponent()
        let videoAlias = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let audioAlias = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: videoAlias); try? FileManager.default.removeItem(at: audioAlias) }
        try FileManager.default.linkItem(at: video, to: videoAlias)
        try FileManager.default.linkItem(at: audio, to: audioAlias)
        let videoAsset = AVURLAsset(url: videoAlias), audioAsset = AVURLAsset(url: audioAlias)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw SocialExtractionError.mergeFailed }
        let composition = AVMutableComposition()
        guard let destinationVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let destinationAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SocialExtractionError.mergeFailed }
        let videoDuration = try await videoAsset.load(.duration), audioDuration = try await audioAsset.load(.duration)
        try destinationVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        try destinationAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero)
        destinationVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw SocialExtractionError.mergeFailed }
        export.outputURL = output; export.outputFileType = .mp4
        await withCheckedContinuation { continuation in export.exportAsynchronously { continuation.resume() } }
        guard export.status == .completed else { throw export.error ?? SocialExtractionError.mergeFailed }
    }
}

actor SocialMediaDownloadService {
    private let extractor: SocialMediaExtracting
    init(extractor: SocialMediaExtracting = PythonSocialExtractor()) { self.extractor = extractor }

    func listFormats(_ url: URL) async throws -> SocialFormatListing { try await extractor.listFormats(url) }
    func resolve(_ url: URL, option: SocialFormatOption?) async throws -> ResolvedSocialMedia { try await extractor.resolve(url, option: option) }

    func download(_ media: ResolvedSocialMedia, sourceURL: URL, mode: SocialDownloadMode, progress: @escaping @Sendable (Double) -> Void) async throws -> SocialDownloadResult {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            let output: URL
            switch media.kind {
            case .progressive(let track):
                if track.useBrowserCookies {
                    // A TikTok page can play one signed rendition while another
                    // metadata rendition returns an HTML gate or an unplayable codec.
                    // Validate each downloaded candidate locally before accepting it.
                    let candidates = [track.url] + track.alternativeURLs
                    var playable: URL?
                    var lastFailure: Error?
                    for (index, url) in candidates.enumerated() {
                        try Task.checkCancellation()
                        let staged = temporary.appendingPathComponent("candidate-\(index).mp4")
                        do {
                            let downloaded = try await TrackDownloadDelegate().download(track.selecting(url)) {
                                progress((Double(index) + $0) / Double(candidates.count))
                            }
                            defer { try? FileManager.default.removeItem(at: downloaded) }
                            try FileManager.default.moveItem(at: downloaded, to: staged)
                            try await validate(staged, expectedAudioOnly: false)
                            playable = staged
                            break
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            lastFailure = error
                            try? FileManager.default.removeItem(at: staged)
                        }
                    }
                    guard let playable else {
                        let reason = lastFailure?.localizedDescription ?? "No video stream was available."
                        throw SocialExtractionError.unsupported(
                            "TikTok exposed \(candidates.count) browser stream option(s), but none could be downloaded as a playable video. Final attempt: \(String(reason.prefix(300)))")
                    }
                    if mode == .audio || mode == .transcribe {
                        output = try await extractAudio(from: playable, in: temporary)
                    } else {
                        output = temporary.appendingPathComponent("download.mp4")
                        try FileManager.default.moveItem(at: playable, to: output)
                    }
                    progress(1)
                } else {
                    let downloaded = try await TrackDownloadDelegate().download(track, progress: progress)
                    if mode == .audio || mode == .transcribe { output = try await extractAudio(from: downloaded, in: temporary) }
                    else { output = temporary.appendingPathComponent("download.mp4"); try FileManager.default.moveItem(at: downloaded, to: output) }
                }
            case .adaptive(let video, let audio):
                if mode == .audio || mode == .transcribe {
                    let downloaded = try await TrackDownloadDelegate().download(audio, progress: progress)
                    output = temporary.appendingPathComponent("download.m4a"); try FileManager.default.moveItem(at: downloaded, to: output)
                } else {
                    let videoFile = try await TrackDownloadDelegate().download(video) { progress($0 * 0.45) }
                    let audioFile = try await TrackDownloadDelegate().download(audio) { progress(0.45 + $0 * 0.45) }
                    output = temporary.appendingPathComponent("download.mp4")
                    try await SocialMediaMerger().merge(video: videoFile, audio: audioFile, output: output)
                    progress(1)
                    try? FileManager.default.removeItem(at: videoFile); try? FileManager.default.removeItem(at: audioFile)
                }
            }
            try await validate(output, expectedAudioOnly: mode != .video)
            return SocialDownloadResult(fileURL: output, title: media.title, sourceURL: sourceURL, shouldTranscribe: mode == .transcribe)
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    private func extractAudio(from source: URL, in folder: URL) async throws -> URL {
        let output = folder.appendingPathComponent("download.m4a")
        try await AudioExtractor().extractAudio(from: source, to: output)
        try? FileManager.default.removeItem(at: source)
        return output
    }

    private func validate(_ url: URL, expectedAudioOnly: Bool) async throws {
        let asset = AVURLAsset(url: url)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard !audio.isEmpty else { throw MediaImportError.noAudioTrack }
        if !expectedAudioOnly {
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else { throw MediaDownloadError.unsupportedContent }
        }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw MediaDownloadError.unsupportedContent }
    }
}
