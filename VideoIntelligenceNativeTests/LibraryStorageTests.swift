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

    func testSystemManagedHLSAssetIsReferencedWithoutCopyAndRemovedOnDelete() async throws {
        let appleManaged = root.appendingPathComponent("AppleManaged", isDirectory: true)
            .appendingPathComponent("offline.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: appleManaged, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: appleManaged.appendingPathComponent("segment"))

        let reference = try await storage.registerOfflineHLSAsset(at: appleManaged)
        XCTAssertTrue(reference.hasPrefix("hlsasset:"))
        let resolved = try await storage.URLFor(relativePath: reference)
        XCTAssertEqual(resolved.standardizedFileURL, appleManaged.standardizedFileURL)
        let documents = await storage.documentsURL
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            documents.appendingPathComponent("Videos/offline.movpkg").path))

        var item = fixtureItem()
        item.mediaRelativePath = reference
        try await storage.deleteMedia(for: item)
        XCTAssertFalse(FileManager.default.fileExists(atPath: appleManaged.path))
    }

    func testOfflineHLSReferenceRejectsArbitraryFileURLs() async throws {
        let notHLS = root.appendingPathComponent("not-an-asset.mp4")
        try Data([1]).write(to: notHLS)
        do {
            _ = try await storage.registerOfflineHLSAsset(at: notHLS)
            XCTFail("Regular videos must not be registered as system-managed offline HLS")
        } catch StorageError.invalidRelativePath {
            // Expected.
        }
    }

    func testLegacyAbsoluteHLSRecoversAfterContainerUUIDChanges() async throws {
        // Simulate the same Library-relative package moved under a new app
        // sandbox UUID by iOS. No copied or relocated package is invented.
        let relocated = root.appendingPathComponent("Library/OfflineVideo/test.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: relocated.appendingPathComponent("segment"))

        let old = URL(fileURLWithPath:
            "/private/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111/Library/OfflineVideo/test.movpkg")
        let reference = "hlsasset:" + Data(old.absoluteString.utf8).base64EncodedString()
        let resolved = try await storage.URLFor(relativePath: reference)
        XCTAssertEqual(resolved.standardizedFileURL, relocated.standardizedFileURL)

        var item = fixtureItem()
        item.mediaRelativePath = reference
        let recovered = await storage.repairOfflineHLSReferences([item])
        XCTAssertEqual(recovered.repaired, 1)
        XCTAssertEqual(recovered.unresolved, 0)
        XCTAssertTrue(recovered.items[0].mediaRelativePath?.hasPrefix("hlsrel:") == true)
        XCTAssertNotEqual(recovered.items[0].mediaRelativePath, reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocated.path))

        try await storage.saveIndex(MediaLibraryIndex(items: recovered.items))
        let reloaded = try await storage.loadIndex()
        let newStorage = LibraryStorage(
            documentsURL: root.appendingPathComponent("Documents"),
            applicationSupportURL: root.appendingPathComponent("Support"),
            cachesURL: root.appendingPathComponent("Caches"))
        let saved = try XCTUnwrap(reloaded.items[0].mediaRelativePath)
        let opened = try await newStorage.URLFor(relativePath: saved)
        XCTAssertEqual(opened.standardizedFileURL, relocated.standardizedFileURL)
    }

    func testNewHLSReferencesArePortableWithinAppContainer() async throws {
        let package = root.appendingPathComponent("Library/SystemMedia/short.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let reference = try await storage.registerOfflineHLSAsset(at: package)
        XCTAssertTrue(reference.hasPrefix("hlsrel:"))
        XCTAssertFalse(reference.contains(root.lastPathComponent))
        let resolved = try await storage.URLFor(relativePath: reference)
        XCTAssertEqual(resolved.standardizedFileURL, package.standardizedFileURL)
    }

    func testMissingHLSPackageIsNotDeletedOrSilentlyRebound() async throws {
        let old = URL(fileURLWithPath:
            "/private/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111/Library/OfflineVideo/missing.movpkg")
        let reference = "hlsasset:" + Data(old.absoluteString.utf8).base64EncodedString()
        var item = fixtureItem()
        item.mediaRelativePath = reference
        let report = await storage.repairOfflineHLSReferences([item])
        XCTAssertEqual(report.repaired, 0)
        XCTAssertEqual(report.unresolved, 1)
        XCTAssertEqual(report.items[0].mediaRelativePath, reference)
        do {
            _ = try await storage.URLFor(relativePath: reference)
            XCTFail("A missing package must not be rebound to a different file")
        } catch StorageError.invalidRelativePath {
            // Expected. Keep the index entry unchanged.
        }
        // Index and transcript remain intact for future recovery.
        try await storage.saveIndex(MediaLibraryIndex(items: report.items))
        let reloaded = try await storage.loadIndex()
        XCTAssertEqual(reloaded.items[0].mediaRelativePath, reference)
    }

    func testOfflineHLSRelativeReferenceRejectsPathTraversal() async throws {
        let unsafe = "hlsrel:" +
            Data("Library/../Documents/other.movpkg".utf8).base64EncodedString()
        do {
            _ = try await storage.URLFor(relativePath: unsafe)
            XCTFail("HLS references must never escape the app container")
        } catch StorageError.invalidRelativePath {
            // Expected.
        }
    }

    private func fixtureItem() -> MediaLibraryItem {
        MediaLibraryItem(id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, title: "Recording", kind: .audio, sourceFilename: "recording.m4a", mediaRelativePath: "Audio/recording.m4a", importedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 4, status: .ready, progress: 0)
    }

    private func fixtureTranscript() -> TranscriptRecord {
        TranscriptRecord(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", title: "Recording", sourceUrl: nil, sourceName: "recording.m4a", createdAt: "2026-11-18T12:00:00Z", duration: 4, engine: "WhisperKit 1.1.1", model: "base.en", text: "Hello", correctedText: nil, segments: [TranscriptSegment(start: 0, end: 1, text: "Hello")])
    }
}
