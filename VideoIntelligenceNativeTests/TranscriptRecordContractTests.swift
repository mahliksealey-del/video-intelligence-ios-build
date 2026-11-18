import XCTest
@testable import VideoIntelligenceNative

final class TranscriptRecordContractTests: XCTestCase {
    func testDecodesTypeScriptCompatibleFixtureWithoutSchemaChanges() throws {
        let data = try fixtureData()
        let record = try JSONDecoder().decode(TranscriptRecord.self, from: data)

        XCTAssertEqual(record.id, "fixture-001")
        XCTAssertEqual(record.sourceUrl, "https://example.invalid/audio/sample")
        XCTAssertEqual(record.sourceName, "sample.m4a")
        XCTAssertEqual(record.createdAt, "2026-11-18T15:30:00.000Z")
        XCTAssertEqual(record.correctedText, "Corrected transcript.")
        XCTAssertEqual(record.segments.count, 2)
    }

    func testSerializationPreservesFixtureKeysAndValues() throws {
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData()) as? NSDictionary)
        let record = try JSONDecoder().decode(TranscriptRecord.self, from: fixtureData())
        let encoded = try JSONEncoder().encode(record)
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)

        XCTAssertEqual(roundTrip, fixture)
    }

    func testOptionalTypeScriptFieldsMayBeAbsent() throws {
        let json = #"{"id":"1","title":"Clip","createdAt":"2026-11-18T00:00:00Z","duration":1,"engine":"test","model":"base.en","text":"Hello","segments":[]}"#
        let record = try JSONDecoder().decode(TranscriptRecord.self, from: Data(json.utf8))

        XCTAssertNil(record.sourceUrl)
        XCTAssertNil(record.sourceName)
        XCTAssertNil(record.correctedText)
    }

    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = bundle.url(forResource: "transcript-record", withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "transcript-record", withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url))
    }
}
