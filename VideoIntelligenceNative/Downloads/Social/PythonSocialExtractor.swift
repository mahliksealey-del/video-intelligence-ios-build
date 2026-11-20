import Foundation

protocol SocialMediaExtracting: Sendable {
    func listFormats(_ url: URL) async throws -> SocialFormatListing
    func resolve(_ url: URL, option: SocialFormatOption?) async throws -> ResolvedSocialMedia
}

final class PythonSocialExtractor: SocialMediaExtracting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mahliksealey.videointelligence.python-extractor")
    private var initialized = false

    func listFormats(_ url: URL) async throws -> SocialFormatListing {
        let cookieFile = try await InstagramSession.shared.temporaryCookieFile(for: url)
        defer { if let cookieFile { try? FileManager.default.removeItem(at: cookieFile) } }
        return try await execute {
            let result: UnsafeMutablePointer<CChar>?
            if let cookieFile {
                result = cookieFile.path.withCString { keraunos_python_list_formats(url.absoluteString, $0) }
            } else {
                result = keraunos_python_list_formats(url.absoluteString, nil)
            }
            guard let result else { throw SocialExtractionError.runtime("Python returned no format response.") }
            defer { free(result) }
            return try SocialExtractionDecoder.listing(Data(String(cString: result).utf8))
        }
    }

    func resolve(_ url: URL, option: SocialFormatOption?) async throws -> ResolvedSocialMedia {
        let cookieFile = try await InstagramSession.shared.temporaryCookieFile(for: url)
        defer { if let cookieFile { try? FileManager.default.removeItem(at: cookieFile) } }
        return try await execute {
            let result: UnsafeMutablePointer<CChar>?
            if let cookieFile {
                result = cookieFile.path.withCString {
                    keraunos_python_extract(url.absoluteString, $0, option?.formatID, option?.isAdaptive == true ? 1 : 0)
                }
            } else {
                result = keraunos_python_extract(url.absoluteString, nil, option?.formatID, option?.isAdaptive == true ? 1 : 0)
            }
            guard let result else { throw SocialExtractionError.runtime("Python returned no extraction response.") }
            defer { free(result) }
            return try SocialExtractionDecoder.resolved(Data(String(cString: result).utf8))
        }
    }

    private func execute<T>(_ body: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { try self.initializeIfNeeded(); continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func initializeIfNeeded() throws {
        guard !initialized else { return }
        guard let resources = Bundle.main.resourceURL else { throw SocialExtractionError.runtime("Application resources are unavailable.") }
        let certificate = resources.appendingPathComponent("app/cacert.pem")
        let status = keraunos_python_init(resources.path, certificate.path)
        guard status == 0 else { throw SocialExtractionError.runtime("Embedded Python initialization failed (\(status)).") }
        initialized = true
    }
}
