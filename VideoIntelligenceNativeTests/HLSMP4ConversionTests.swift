import Foundation
import XCTest
@testable import VideoIntelligenceNative

final class HLSMP4ConversionTests: XCTestCase {
    let base = URL(string: "https://video.example.com/path/playlist.m3u8")!

    func testMasterSelectsHighestBitrateFromActualSelectedPlaylist() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        low/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=3800000,RESOLUTION=1920x1080
        high/index.m3u8
        """
        guard case .master(let selected) = try HLSPlaylistPlanner.parse(playlist, at: base) else {
            return XCTFail("Expected master playlist")
        }
        XCTAssertEqual(selected.variantURL.absoluteString,
                       "https://video.example.com/path/high/index.m3u8")
        XCTAssertNil(selected.alternateAudioURL)
    }

    func testAudioGroupWithoutURIIsMuxedIntoSelectedVariant() throws {
        // HLS RFC 8216 explicitly permits URI to be omitted when the audio
        // rendition is included in the video variant itself.
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="main",NAME="English",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=1400000,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="main"
        muxed.m3u8
        """
        guard case .master(let pick) = try HLSPlaylistPlanner.parse(master, at: base) else {
            return XCTFail("Expected master playlist")
        }
        XCTAssertNil(pick.alternateAudioURL)
        XCTAssertEqual(pick.variantURL.lastPathComponent, "muxed.m3u8")
    }

    func testAudioGroupWithURIRetainsSeparateAudioForMerge() throws {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="English, Stereo",DEFAULT=YES,URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="French",DEFAULT=NO,URI="audio/fr.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,AUDIO="sound",CODECS="avc1.640028,mp4a.40.2"
        video/high.m3u8
        """
        guard case .master(let pick) = try HLSPlaylistPlanner.parse(master, at: base) else {
            return XCTFail("Expected master playlist")
        }
        XCTAssertEqual(pick.variantURL.lastPathComponent, "high.m3u8")
        XCTAssertEqual(pick.alternateAudioURL?.absoluteString,
                       "https://video.example.com/path/audio/en.m3u8")
    }

    func testFragmentedMP4ByteRangesAndImplicitOffsets() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="combined.mp4",BYTERANGE="801@0"
        #EXTINF:3,
        #EXT-X-BYTERANGE:2400@801
        combined.mp4
        #EXTINF:3,
        #EXT-X-BYTERANGE:2800
        combined.mp4
        #EXT-X-ENDLIST
        """
        guard case .media(let plan) = try HLSPlaylistPlanner.parse(playlist, at: base) else {
            return XCTFail("Expected fMP4 plan")
        }
        XCTAssertEqual(plan.initializationRange, HLSByteRange(length: 801, offset: 0))
        XCTAssertEqual(plan.ranges[0], HLSByteRange(length: 2400, offset: 801))
        XCTAssertEqual(plan.ranges[1], HLSByteRange(length: 2800, offset: 3201))
        XCTAssertEqual(plan.ranges[1]?.lastByte, 6000)
    }

    func testTransportStreamByteRangesAreNotRejected() throws {
        let playlist = """
        #EXTM3U
        #EXTINF:5,
        #EXT-X-BYTERANGE:1880@0
        media.ts
        #EXTINF:5,
        #EXT-X-BYTERANGE:1880
        media.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let plan) = try HLSPlaylistPlanner.parse(playlist, at: base) else {
            return XCTFail("Expected TS plan")
        }
        XCTAssertEqual(plan.format, .ts)
        XCTAssertEqual(plan.ranges.map { $0?.offset }, [0, 1880])
    }

    func testImplicitByteRangeRequiresPreviousSameResource() {
        let invalid = """
        #EXTM3U
        #EXTINF:1,
        #EXT-X-BYTERANGE:1880@0
        old.ts
        #EXTINF:1,
        #EXT-X-BYTERANGE:1880
        new.ts
        #EXT-X-ENDLIST
        """
        XCTAssertThrowsError(try HLSPlaylistPlanner.parse(invalid, at: base))
    }

    func testLowLatencyVODCanUseCompleteSegmentsWithoutPartialHints() throws {
        let source = """
        #EXTM3U
        #EXT-X-PART:URI="partial.m4s",DURATION=0.5
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4,
        complete.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let plan) = try HLSPlaylistPlanner.parse(source, at: base) else {
            return XCTFail("Expected complete VOD")
        }
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(plan.segments[0].lastPathComponent, "complete.m4s")
    }

    func testTransportStreamVODCanBeRemuxedWithoutMovingOfflinePackage() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:5.0,
        part000.ts
        #EXTINF:3.0,
        ../part001.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let plan) = try HLSPlaylistPlanner.parse(playlist, at: base) else {
            return XCTFail("Expected VOD")
        }
        XCTAssertEqual(plan.format, .ts)
        XCTAssertNil(plan.initialization)
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[1].absoluteString, "https://video.example.com/part001.ts")
    }

    func testFragmentedMP4VODIdentifiesInitAndSegments() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        seg_01.m4s
        #EXTINF:4.0,
        seg_02.m4s
        #EXT-X-ENDLIST
        """
        guard case .media(let plan) = try HLSPlaylistPlanner.parse(playlist, at: base) else {
            return XCTFail("Expected fMP4 VOD")
        }
        XCTAssertEqual(plan.format, .fragmentedMP4)
        XCTAssertEqual(plan.initialization?.lastPathComponent, "init.mp4")
        XCTAssertEqual(plan.segments.map(\.lastPathComponent), ["seg_01.m4s", "seg_02.m4s"])
    }

    func testRejectsLivePlaylistInsteadOfSavingIncompleteVideo() {
        let live = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6,
        seg.ts
        """
        XCTAssertThrowsError(try HLSPlaylistPlanner.parse(live, at: base)) { error in
            XCTAssertEqual(error as? HLSMP4Error, .liveNotSupported)
        }
    }

    func testRejectsProtectedAndUnsupportedPlaylistFeatures() {
        let protected = """
        #EXTM3U
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="license"
        #EXTINF:6,
        seg.ts
        #EXT-X-ENDLIST
        """
        XCTAssertThrowsError(try HLSPlaylistPlanner.parse(protected, at: base)) { error in
            XCTAssertEqual(error as? HLSMP4Error, .protectedMedia)
        }
        let unsupportedDelta = """
        #EXTM3U
        #EXT-X-SKIP:SKIPPED-SEGMENTS=10
        #EXTINF:6,
        seg.m4s
        #EXT-X-ENDLIST
        """
        XCTAssertThrowsError(try HLSPlaylistPlanner.parse(unsupportedDelta, at: base)) { error in
            XCTAssertEqual(error as? HLSMP4Error,
                           .specificUnsupported("delta-playlist updates"))
        }
    }

    func testRejectsPrivateNetworkAndNonHTTPSSegmentURLs() {
        XCTAssertThrowsError(try HLSPlaylistPlanner.resolve(
            "http://127.0.0.1/private.ts", relativeTo: base))
        XCTAssertThrowsError(try HLSPlaylistPlanner.resolve(
            "https://192.168.1.2/private.ts", relativeTo: base))
        XCTAssertThrowsError(try HLSPlaylistPlanner.resolve(
            "https://internal.local/private.ts", relativeTo: base))
        XCTAssertThrowsError(try HLSPlaylistPlanner.resolve(
            "https://video.example.com/private/{$token}.ts", relativeTo: base))
    }

    func testNativeRemuxHasIndependentCancellationToken() {
        guard let token = hls_remux_cancel_token_create() else {
            return XCTFail("Cancellation token allocation failed")
        }
        XCTAssertEqual(hls_remux_cancel_token_is_requested(token), 0)
        hls_remux_cancel_token_request(token)
        XCTAssertEqual(hls_remux_cancel_token_is_requested(token), 1)
        hls_remux_cancel_token_free(token)
    }

    func testLegacyLibraryRecordDecodesWithoutPlaylistReference() throws {
        let old = MediaLibraryItem(
            id: UUID(), title: "Offline video", kind: .video,
            sourceFilename: "offline.movpkg", sourceURL: "https://example.com/watch",
            mediaRelativePath: "hlsasset:example", importedAt: Date(),
            duration: 12, status: .ready, progress: 0)
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder.library.encode(old)) as! [String: Any]
        json.removeValue(forKey: "hlsPlaylistURL")
        let payload = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder.library.decode(MediaLibraryItem.self, from: payload)
        XCTAssertNil(restored.hlsPlaylistURL)
        XCTAssertEqual(restored.mediaRelativePath, old.mediaRelativePath)
    }

    func testHLSAndMP4QueueJobsCanCoexistForSamePlaylist() {
        let url = URL(string: "https://cdn.example.com/a.m3u8")!
        let page = URL(string: "https://example.com/watch")!
        let candidate = UniversalWebMediaCandidate(
            url: url, pageURL: page, title: "Watch",
            userAgent: nil, kind: .hls, isPlaying: true)
        let native = BrowserDownloadRequest.hls(candidate)
        let mp4 = BrowserDownloadRequest.hlsMP4(candidate)
        XCTAssertNotEqual(native.dedupeKey, mp4.dedupeKey)
        XCTAssertEqual(native.mediaURL, mp4.mediaURL)
    }
}
