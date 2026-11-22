@testable import OWAWidget
import XCTest

/// Which search requests may start a session: only a new search. The requests after its first
/// page (later pages, per-word checks, the late filters) go on in the open one or are not made.
final class OWAMailSearchSessionTests: XCTestCase {
    private let open = OWAMailSearchSession(id: "S1", scope: .mailbox)

    func testNewSearchAlwaysStartsASession() {
        XCTAssertEqual(OWAMailSearchSession.decision(current: open, scope: .mailbox, use: .fresh), .start)
        XCTAssertEqual(OWAMailSearchSession.decision(current: nil, scope: .mailbox, use: .fresh), .start)
    }

    func testNextPageReusesOrStarts() {
        XCTAssertEqual(OWAMailSearchSession.decision(current: open, scope: .mailbox, use: .openOrNew), .reuse)
        XCTAssertEqual(OWAMailSearchSession.decision(current: nil, scope: .mailbox, use: .openOrNew), .start)
        XCTAssertEqual(OWAMailSearchSession.decision(current: open, scope: .distinguished(.inbox), use: .openOrNew), .start)
    }

    func testOpenOnlyNeverStartsOne() {
        XCTAssertEqual(OWAMailSearchSession.decision(current: open, scope: .mailbox, use: .openOnly), .reuse)
        XCTAssertEqual(OWAMailSearchSession.decision(current: nil, scope: .mailbox, use: .openOnly), .unavailable)
        XCTAssertEqual(OWAMailSearchSession.decision(current: open, scope: .distinguished(.inbox), use: .openOnly), .unavailable)
    }
}
