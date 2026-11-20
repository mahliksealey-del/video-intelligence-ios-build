import XCTest
@testable import VideoIntelligenceNative

final class YouTubeRangeDownloaderTests: XCTestCase {
    private func track(_ raw: String, chunkSize: Int?) -> SocialMediaTrack {
        SocialMediaTrack(
            url: URL(string: raw)!,
            headers: [:],
            fileExtension: "mp4",
            chunkSize: chunkSize,
            approximateBytes: nil
        )
    }

    func testRangeModeAppliesOnlyToChunkedGooglevideoMedia() {
        XCTAssertTrue(YouTubeRangeDownloader.shouldUse(
            track("https://rr1---sn-123.googlevideo.com/videoplayback?expire=123", chunkSize: 10_485_760)))
        XCTAssertTrue(YouTubeRangeDownloader.shouldUse(
            track("https://googlevideo.com/videoplayback", chunkSize: 4_194_304)))
        XCTAssertFalse(YouTubeRangeDownloader.shouldUse(
            track("https://rr1---sn-123.googlevideo.com/videoplayback", chunkSize: nil)))
        XCTAssertFalse(YouTubeRangeDownloader.shouldUse(
            track("https://rr1---sn-123.googlevideo.com/videoplayback", chunkSize: 0)))
        XCTAssertFalse(YouTubeRangeDownloader.shouldUse(
            track("https://www.instagram.com/reel/abc", chunkSize: 10_485_760)))
        XCTAssertFalse(YouTubeRangeDownloader.shouldUse(
            track("https://v16.tiktokcdn.com/video.mp4", chunkSize: 10_485_760)))
        XCTAssertFalse(YouTubeRangeDownloader.shouldUse(
            track("https://googlevideo.com.evil.example/video.mp4", chunkSize: 10_485_760)))
    }

    func testByteRangeUsesBoundedInclusiveOffsets() {
        XCTAssertEqual(YouTubeRangeDownloader.byteRange(start: 0, chunkSize: 1_024, total: nil),
                       "bytes=0-1023")
        XCTAssertEqual(YouTubeRangeDownloader.byteRange(start: 1_024, chunkSize: 1_024, total: 2_048),
                       "bytes=1024-2047")
        XCTAssertEqual(YouTubeRangeDownloader.byteRange(start: 1_024, chunkSize: 1_024, total: 1_600),
                       "bytes=1024-1599")
        XCTAssertEqual(YouTubeRangeDownloader.byteRange(start: 0, chunkSize: 50_000_000, total: nil),
                       "bytes=0-10485759")
        XCTAssertEqual(YouTubeRangeDownloader.byteRange(start: 1_999_999_990,
                         chunkSize: 50_000_000, total: nil),
                       "bytes=1999999990-1999999999")
    }

    func testContentRangeParsesValid206ResponseAndRejectsUnsafeValues() {
        let part = YouTubeRangeDownloader.contentRange("bytes 0-1023/2048")
        XCTAssertEqual(part?.start, 0)
        XCTAssertEqual(part?.end, 1023)
        XCTAssertEqual(part?.total, 2048)
        let next = YouTubeRangeDownloader.contentRange("Bytes 1024-2047/2048")
        XCTAssertEqual(next?.start, 1024)
        XCTAssertEqual(next?.end, 2047)

        for invalid in [
            nil, "", "0-100/200", "bytes */200", "bytes 0-9/*",
            "bytes 100-99/200", "bytes 0-100/100", "bytes -1-10/100",
            "bytes 0-10/9999999999999", "bytes 0-10", "bytes 0-10/0"
        ] as [String?] {
            XCTAssertNil(YouTubeRangeDownloader.contentRange(invalid),
                         "Invalid range should be rejected: \(invalid ?? "nil")")
        }
    }
}
