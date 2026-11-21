import XCTest
@testable import VideoIntelligenceNative

final class TorRoutingTests: XCTestCase {
    func testOfficialOrbotUniversalLinksOnly() {
        XCTAssertEqual(TorRoutingLinks.start.absoluteString, "https://orbot.app/rc/start")
        XCTAssertEqual(TorRoutingLinks.show.absoluteString, "https://orbot.app/rc/show")
        XCTAssertEqual(TorRoutingLinks.download.absoluteString, "https://orbot.app/download")
        XCTAssertEqual(TorRoutingLinks.check.absoluteString, "https://check.torproject.org/api/ip")
        XCTAssertEqual(TorRoutingLinks.start.scheme, "https")
    }

    func testTorPositiveResponseReportsObservedExitIP() throws {
        let payload = Data(#"{"IsTor":true,"IP":"198.51.100.8"}"#.utf8)
        XCTAssertEqual(try TorRouteVerifier.interpret(payload), .confirmed(exitIP: "198.51.100.8"))
    }

    func testNonTorResponseMustNeverReportProtected() throws {
        let payload = Data(#"{"IsTor":false,"IP":"203.0.113.12"}"#.utf8)
        XCTAssertEqual(try TorRouteVerifier.interpret(payload), .notConfirmed(observedIP: "203.0.113.12"))
    }

    func testFailureAndMalformedResponsesCannotClaimTor() {
        let malformed = [
            #"{"IsTor":true}"#,
            #"{"IP":"203.0.113.1"}"#,
            #"{"IsTor":"true","IP":"198.51.100.8"}"#,
            #"{"IsTor":true,"IP":""}"#,
            #"{"IsTor":true,"IP":"bad IP"}"#,
            "<html>not JSON</html>",
        ]
        for source in malformed {
            XCTAssertThrowsError(try TorRouteVerifier.interpret(Data(source.utf8)), "Must reject \(source)")
        }
    }
}
