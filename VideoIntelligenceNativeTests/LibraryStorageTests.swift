import XCTest
@testable import VideoIntelligenceNative

final class LibraryStorageTests: XCTestCase {
    private var root: URL!
    private var storage: LibraryStorage!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        storage = LibraryStorage(documentsURL: root.appendingPathComponent("Documents"), applicationSupportURL: root.appendingPathComponent("Support"), cachesURL: root.appendingPathComponent("Caches"))
        try await storage.prepareDirectories()
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    func testCreatesUserFacingFoldersWithoutRedundantAppFolder() async throws {
        let documents = await storage.documentsURL
        for folder in ["Videos", "Audio", "Transcripts", "Exports"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: documents.appendingPathComponent(folder).path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Video Intelligence").path))
    }

    func testIndexPersistsAcrossStorageInstances() async throws {
        let item = fixtureItem()
        try await storage.saveIndex(MediaLibraryIndex(items: [item]))
        let reloaded = try await storage.loadIndex()
        XCTAssertEqual(reloaded.items, [item])
    }

    func testDuplicateNamesProduceCollisionFreeDestinations() async throws {
        let source = root.appendingPathComponent("recording.m4a")
        try Data([1, 2, 3]).write(to: source)
        let first = try await storage.importMedia(from: source, kind: .audio, id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let second = try await storage.importMedia(from: source, kind: .audio, id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        XCTAssertNotEqual(first, second)
    }

    func testDeletingMediaPreservesTranscript() async throws {
        var item = fixtureItem()
        let media = try await storage.URLFor(relativePath: item.mediaRelativePath!)
        try Data([1]).write(to: media)
        let transcript = fixtureTranscript()
        item.transcriptRelativePath = try await storage.writeTranscript(transcript, id: item.id)
        try await storage.deleteMedia(for: item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
        let savedTranscript = try await storage.loadTranscript(relativePath: item.transcriptRelativePath!)
        XCTAssertEqual(savedTranscript, transcript)
    }

    private func fixtureItem() -> MediaLibraryItem {
        MediaLibraryItem(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, title: "Recording", kind: .audio, sourceFilename: "recording.m4a", mediaRelativePath: "Audio/recording.m4a", importedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 4, status: .ready, progress: 0)
    }

    private func fixtureTranscript() -> TranscriptRecord {
        TranscriptRecord(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", title: "Recording", sourceUrl: nil, sourceName: "recording.m4a", createdAt: "2026-11-18T12:00:00Z", duration: 4, engine: "WhisperKit 1.1.1", model: "base.en", text: "Hello", correctedText: nil, segments: [TranscriptSegment(start: 0, end: 1, text: "Hello")])
    }
}
