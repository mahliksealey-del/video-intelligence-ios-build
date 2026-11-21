import AVFoundation
import Foundation

/// Explicit offline VOD download for detected HLS manifests.
/// Uses Apple's native HLS offline asset package (.movpkg), NOT MP4 export.
/// Does not attempt to decrypt DRM, record live streams, or bypass site access.
/// A separate instance is created for each user-initiated download.
final class HLSOfflineDownloadService: NSObject, AVAssetDownloadDelegate, @unchecked Sendable {
    enum DownloadError: LocalizedError {
        case invalidURL
        case cannotStart
        case missingOfflinePackage
        case unsupportedPackage

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "This is not a safe HTTPS HLS playlist."
            case .cannotStart:
                return "iOS could not start the offline HLS download. This stream might be live, restricted, or unsupported."
            case .missingOfflinePackage:
                return "iOS finished the HLS request but did not return an offline video package."
            case .unsupportedPackage:
                return "The HLS download did not produce a supported offline package."
            }
        }
    }

    static func supports(_ candidate: UniversalWebMediaCandidate) -> Bool {
        candidate.kind == .hls
        && candidate.url.scheme?.lowercased() == "https"
        && URLSafetyPolicy.isPublic(candidate.url)
        && candidate.url.path.lowercased().hasSuffix(".m3u8")
    }

    private var session: AVAssetDownloadURLSession?
    private var task: AVAssetDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloadedLocation: URL?
    private var onProgress: (@Sendable (Double) -> Void)?

    func download(_ candidate: UniversalWebMediaCandidate,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard Self.supports(candidate) else { throw DownloadError.invalidURL }
        try DownloadStoragePolicy.check()

        let location = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                self.continuation = continuation
                self.onProgress = progress

                // AVAssetDownloadURLSession requires a background session even
                // when the download is initiated in the foreground.
                let config = URLSessionConfiguration.background(
                    withIdentifier: "com.example.videointelligence.hls." + UUID().uuidString)
                config.isDiscretionary = false
                config.waitsForConnectivity = true

                let session = AVAssetDownloadURLSession(
                    configuration: config, assetDownloadDelegate: self,
                    delegateQueue: OperationQueue.main)
                self.session = session

                let asset = AVURLAsset(url: candidate.url)
                guard let downloadTask = session.makeAssetDownloadTask(
                    asset: asset,
                    assetTitle: candidate.title,
                    assetArtworkData: nil,
                    options: nil
                ) else {
                    self.finish(with: .failure(DownloadError.cannotStart))
                    return
                }
                self.task = downloadTask
                downloadTask.resume()
            }
        }, onCancel: {
            Task { @MainActor in self.task?.cancel() }
        })
        return location
    }

    // The system assigns the offline package's location; do not invent
    // a .mp4 path or try to download the m3u8 playlist as one video file.
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    willDownloadTo location: URL) {
        downloadedLocation = location
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask,
                    didLoad timeRange: CMTimeRange, totalTimeRangesLoaded loadedTimeRanges: [NSValue],
                    timeRangeExpectedToLoad: CMTimeRange) {
        let expected = timeRangeExpectedToLoad.duration.seconds
        guard expected.isFinite, expected > 0 else { return }
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + max(0, $1.timeRangeValue.duration.seconds) }
        onProgress?(max(0, min(0.99, loaded / expected)))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
            return
        }
        guard let location = downloadedLocation,
              FileManager.default.fileExists(atPath: location.path) else {
            finish(with: .failure(DownloadError.missingOfflinePackage))
            return
        }
        guard location.pathExtension.lowercased() == "movpkg" else {
            finish(with: .failure(DownloadError.unsupportedPackage))
            return
        }
        onProgress?(1)
        finish(with: .success(location))
    }

    private func finish(with result: Result<URL, Error>) {
        let completion = continuation
        continuation = nil
        task = nil
        downloadedLocation = nil
        onProgress = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion?.resume(with: result)
    }
}
