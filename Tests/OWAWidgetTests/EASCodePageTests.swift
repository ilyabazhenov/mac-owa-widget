import XCTest
@testable import OWAWidget

/// Literal assertions on the token tables.
///
/// These exist because a wrong token in a *request* is silent: the server ignores the
/// field or reads it as something else, and the symptom is missing data rather than an
/// error. A typo in a table is otherwise found only by staring at a hex dump.
final class EASCodePageTests: XCTestCase {

    // MARK: Calendar — page 4, verified against the published specification

    func testCalendarPageHasNoTokenTen() {
        // The published table jumps from Category (0x0F) straight to DtStamp (0x11).
        // Mapping anything to 0x10 here would mis-decode every calendar item that used it.
        XCTAssertNil(EASCodePages.calendar[0x10])
        XCTAssertEqual(EASCodePages.calendar[0x0F], "Category")
        XCTAssertEqual(EASCodePages.calendar[0x11], "DtStamp")
    }

    func testCalendarTokensUsedByTheMapper() {
        XCTAssertEqual(CAL.timezone.code, 0x05)
        XCTAssertEqual(CAL.allDayEvent.code, 0x06)
        XCTAssertEqual(CAL.email.code, 0x09)        // "Email", not "AttendeeEmail"
        XCTAssertEqual(CAL.name.code, 0x0A)         // "Name", not "AttendeeName"
        XCTAssertEqual(CAL.subject.code, 0x26)
        XCTAssertEqual(CAL.startTime.code, 0x27)
        XCTAssertEqual(CAL.endTime.code, 0x12)
        XCTAssertEqual(CAL.meetingStatus.code, 0x18)
    }

    func testCalendarRecurrenceTokens() {
        XCTAssertEqual(CAL.recurrence.code, 0x1B)
        XCTAssertEqual(CAL.type.code, 0x1C)
        XCTAssertEqual(CAL.until.code, 0x1D)
        XCTAssertEqual(CAL.occurrences.code, 0x1E)
        XCTAssertEqual(CAL.interval.code, 0x1F)
        XCTAssertEqual(CAL.dayOfWeek.code, 0x20)
        XCTAssertEqual(CAL.dayOfMonth.code, 0x21)
        XCTAssertEqual(CAL.weekOfMonth.code, 0x22)
        XCTAssertEqual(CAL.monthOfYear.code, 0x23)
        XCTAssertEqual(CAL.exceptions.code, 0x14)
        XCTAssertEqual(CAL.exception.code, 0x13)
        XCTAssertEqual(CAL.exceptionStartTime.code, 0x16)
        XCTAssertEqual(CAL.deleted.code, 0x15)
    }

    // MARK: Collisions across pages

    func testSameTokenMeansDifferentThingsOnDifferentPages() {
        XCTAssertEqual(ST.set.code, 0x08)
        XCTAssertEqual(PR.policyType.code, 0x08)
        XCTAssertNotEqual(ST.set, PR.policyType, "same code, different page — must not compare equal")

        XCTAssertEqual(EASCodePages.name(page: 18, code: 0x08), "Set")
        XCTAssertEqual(EASCodePages.name(page: 14, code: 0x08), "PolicyType")
    }

    func testBodyLivesOnAirSyncBaseNotCalendar() {
        XCTAssertEqual(ASB.body.page, 17)
        XCTAssertEqual(ASB.body.code, 0x0A)
        XCTAssertEqual(ASB.data.code, 0x0B)
        // Page 4 keeps a legacy 2.5-only body at 0x0B; it must not be mistaken for the real one.
        XCTAssertEqual(EASCodePages.calendar[0x0B], "CalBody25")
    }

    func testTagEqualityIgnoresName() {
        let a = WBTag(page: 4, code: 0x26, name: "Subject")
        let b = WBTag(page: 4, code: 0x26, name: "whatever")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    // MARK: Server-verified pages

    func testProvisionAndSettingsTokens() {
        XCTAssertEqual(ST.deviceInformation.code, 0x16)
        XCTAssertEqual(ST.userAgent.code, 0x20)
        XCTAssertEqual(PR.provision.code, 0x05)
        XCTAssertEqual(PR.policyKey.code, 0x09)
    }

    func testFolderHierarchyTokens() {
        XCTAssertEqual(FH.folderSync.code, 0x16)
        XCTAssertEqual(FH.syncKey.code, 0x12)
        XCTAssertEqual(FH.type.code, 0x0A)
    }

    // MARK: Unmapped tokens

    func testUnmappedTokenBecomesAVisiblePlaceholder() {
        // This is the discovery mechanism: dump a real response and every pN_0xNN is a
        // token this build does not know about.
        XCTAssertEqual(EASCodePages.name(page: 4, code: 0x7E), "p4_0x7E")
        XCTAssertEqual(EASCodePages.name(page: 99, code: 0x05), "p99_0x05")
    }

    func testEveryRegisteredPageHasTokens() {
        for (page, table) in EASCodePages.pages {
            XCTAssertFalse(table.isEmpty, "code page \(page) is registered but empty")
        }
    }
}

/// Finding tokens this build does not know about.
///
/// The only practical way to verify a code-page table against a real server: an unmapped token
/// is a field that arrived and went nowhere, and nothing else reports it.
final class EASUnmappedTokenTests: XCTestCase {

    func testAFullyMappedDocumentReportsNothing() throws {
        let writer = WBXMLWriter()
        writer.node(FH.folderSync) { writer.leaf(FH.syncKey, "0") }
        let tree = try WBXMLReader.parse(writer.data)
        XCTAssertTrue(tree.unmappedTokens.isEmpty)
    }

    func testUnknownTokensAreReportedByName() throws {
        let writer = WBXMLWriter()
        writer.node(CAL.subject) {
            // A token the calendar table does not define — the shape of a protocol version
            // carrying a field this build predates.
            writer.leaf(WBTag(page: 4, code: 0x3E, name: "unknown"), "value")
        }
        let tree = try WBXMLReader.parse(writer.data)
        XCTAssertEqual(tree.unmappedTokens, ["p4_0x3E"])
    }

    func testReportingIsDeduplicatedAcrossTheTree() throws {
        let mystery = WBTag(page: 10, code: 0x22, name: "unknown")
        let writer = WBXMLWriter()
        writer.node(RR.resolveRecipients) {
            writer.node(RR.recipient) { writer.leaf(mystery, "a") }
            writer.node(RR.recipient) { writer.leaf(mystery, "b") }
        }
        let tree = try WBXMLReader.parse(writer.data)
        XCTAssertEqual(tree.unmappedTokens, ["p10_0x22"], "one name per distinct token, not per occurrence")
    }

    func testAnEntirelyUnknownPageIsReported() throws {
        let writer = WBXMLWriter()
        writer.node(WBTag(page: 25, code: 0x05, name: "unknown")) { writer.text("x") }
        let tree = try WBXMLReader.parse(writer.data)
        XCTAssertEqual(tree.unmappedTokens, ["p25_0x05"])
    }
}
