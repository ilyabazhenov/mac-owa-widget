import XCTest
@testable import OWAWidget

/// Codec tests that need neither a server nor credentials.
///
/// The load-bearing one is `testFolderSyncMatchesSpecificationBytes`: it pins the encoder
/// against the worked example in the published specification, so a regression in the
/// header, the page-switch or the tag-with-content bit fails here rather than as
/// unexplained server errors.
final class EASWBXMLTests: XCTestCase {

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testRedirectDelegateRejectsUnconfiguredHosts() {
        let delegate = EASRedirectDelegate(configuredHost: "mail.example.com")
        XCTAssertTrue(delegate.permitsRedirection(to: URL(string: "https://MAIL.example.com/next")))
        XCTAssertFalse(delegate.permitsRedirection(to: URL(string: "https://evil.example.com/next")))
        XCTAssertFalse(delegate.permitsRedirection(to: nil))
    }

    // MARK: Encoding

    func testFolderSyncMatchesSpecificationBytes() {
        let writer = WBXMLWriter()
        writer.node(FH.folderSync) { writer.leaf(FH.syncKey, "0") }

        // 03 WBXML 1.3 · 01 public id · 6a UTF-8 · 00 no string table
        // 00 07 switch to page 7 · 56 FolderSync+content · 52 SyncKey+content
        // 03 "0" 00 inline string · 01 01 two END markers
        XCTAssertEqual(hex(writer.data), "03016a000007565203300001" + "01")
    }

    func testRoundTripOfOwnFolderSync() throws {
        let writer = WBXMLWriter()
        writer.node(FH.folderSync) { writer.leaf(FH.syncKey, "0") }

        let tree = try WBXMLReader.parse(writer.data)
        XCTAssertEqual(tree.first(FH.syncKey)?.text, "0")
    }

    func testPageSwitchSurvivesRoundTrip() throws {
        let writer = WBXMLWriter()
        writer.node(AS.sync) {
            writer.node(AS.collections) {
                writer.node(AS.collection) {
                    writer.leaf(AS.syncKey, "42")
                    writer.leaf(AS.collectionId, "5")
                    writer.node(AS.options) {
                        writer.leaf(AS.filterType, "0")
                        writer.node(ASB.bodyPreference) {        // page 17
                            writer.leaf(ASB.type, "2")
                            writer.leaf(ASB.truncationSize, "32768")
                        }
                    }
                }
            }
        }

        let tree = try WBXMLReader.parse(writer.data)
        XCTAssertEqual(tree.first(AS.syncKey)?.text, "42")
        XCTAssertEqual(tree.first(AS.filterType)?.text, "0")
        XCTAssertEqual(tree.first(ASB.truncationSize)?.text, "32768")
    }

    func testProvisionPutsDeviceInformationBeforePolicies() throws {
        let writer = WBXMLWriter()
        writer.node(PR.provision) {
            writer.node(ST.deviceInformation) {                   // page 18
                writer.node(ST.set) {
                    writer.leaf(ST.model, "MWLY2ZD/A")
                    writer.leaf(ST.friendlyName, "iPhone")
                    writer.leaf(ST.os, "iOS 26.1 (23B85)")
                    writer.leaf(ST.osLanguage, "en-us")
                    writer.leaf(ST.userAgent, "Apple-iPhone14C1/2101.331")
                }
            }
            writer.node(PR.policies) {                            // back to page 14
                writer.node(PR.policy) {
                    writer.leaf(PR.policyType, "MS-EAS-Provisioning-WBXML")
                }
            }
        }

        let tree = try WBXMLReader.parse(writer.data)
        let provision = try XCTUnwrap(tree.first(PR.provision))

        // Exchange rejects the request with Status=165 unless DeviceInformation comes first.
        XCTAssertEqual(provision.children.compactMap(\.tag?.name),
                       ["DeviceInformation", "Policies"])
        XCTAssertEqual(tree.first(ST.model)?.text, "MWLY2ZD/A")
        XCTAssertEqual(tree.first(ST.userAgent)?.text, "Apple-iPhone14C1/2101.331")
        XCTAssertEqual(tree.first(PR.policyType)?.text, "MS-EAS-Provisioning-WBXML")
    }

    // MARK: Page-aware navigation

    /// The same token byte means different things on different pages. `Set` is `0x08` on
    /// page 18 and `PolicyType` is `0x08` on page 14; `Status` exists on pages 0, 7, 14 and 18.
    /// Matching on the name alone would silently return the wrong node.
    func testLookupDistinguishesSameTokenOnDifferentPages() throws {
        let writer = WBXMLWriter()
        writer.node(PR.provision) {
            writer.node(ST.deviceInformation) {
                writer.leaf(ST.status, "1")          // page 18, token 0x06
            }
            writer.leaf(PR.status, "165")            // page 14, token 0x0B
        }

        let tree = try WBXMLReader.parse(writer.data)
        XCTAssertEqual(tree.first(ST.status)?.text, "1")
        XCTAssertEqual(tree.first(PR.status)?.text, "165")
        XCTAssertNil(tree.first(AS.status), "AirSync Status is not present in this document")
    }

    func testChildLookupIsScopedToDirectChildren() throws {
        let writer = WBXMLWriter()
        writer.node(AS.sync) {
            writer.node(AS.collections) {
                writer.node(AS.collection) { writer.leaf(AS.syncKey, "7") }
            }
        }

        let tree = try WBXMLReader.parse(writer.data)
        let sync = try XCTUnwrap(tree.first(AS.sync))
        XCTAssertNil(sync.child(AS.syncKey), "SyncKey is a grandchild, not a child")
        XCTAssertEqual(sync.first(AS.syncKey)?.text, "7", "depth-first search still finds it")
    }

    // MARK: Decoding a response

    func testParsesCalendarSyncResponse() throws {
        // Hand-built to match the shape Exchange returns for a calendar collection.
        let writer = WBXMLWriter()
        writer.node(AS.sync) {
            writer.node(AS.collections) {
                writer.node(AS.collection) {
                    writer.leaf(AS.syncKey, "9")
                    writer.leaf(AS.collectionId, "20")
                    writer.leaf(AS.status, "1")
                    writer.node(AS.commands) {
                        writer.node(AS.add) {
                            writer.leaf(AS.serverId, "20:3")
                            writer.node(AS.applicationData) {
                                writer.leaf(CAL.subject, "Планёрка команды")
                                writer.leaf(CAL.organizerName, "Иван Петров")
                                writer.leaf(CAL.organizerEmail, "ivan@example.com")
                                writer.leaf(CAL.startTime, "20260915T070000Z")
                                writer.leaf(CAL.endTime, "20260915T073000Z")
                                writer.leaf(CAL.allDayEvent, "0")
                                writer.leaf(CAL.meetingStatus, "1")
                                writer.node(CAL.attendees) {
                                    writer.node(CAL.attendee) {
                                        writer.leaf(CAL.email, "a@example.com")
                                        writer.leaf(CAL.name, "Анна")
                                    }
                                }
                                writer.node(ASB.body) {           // page 17, not page 4
                                    writer.leaf(ASB.type, "1")
                                    writer.leaf(ASB.data, "первая  строка\n\nвторая")
                                }
                            }
                        }
                    }
                }
            }
        }

        let tree = try WBXMLReader.parse(writer.data)
        let collection = try XCTUnwrap(tree.first(AS.collection))
        XCTAssertEqual(collection.value(AS.status), "1")

        let adds = try XCTUnwrap(collection.child(AS.commands)).all(AS.add)
        XCTAssertEqual(adds.count, 1)

        let add = try XCTUnwrap(adds.first)
        XCTAssertEqual(add.value(AS.serverId), "20:3")

        let item = try XCTUnwrap(add.child(AS.applicationData))
        XCTAssertEqual(item.value(CAL.subject), "Планёрка команды")
        XCTAssertEqual(item.value(CAL.organizerName), "Иван Петров")
        XCTAssertEqual(item.value(CAL.allDayEvent), "0")

        let attendee = try XCTUnwrap(item.child(CAL.attendees)?.child(CAL.attendee))
        XCTAssertEqual(attendee.value(CAL.name), "Анна")

        // Body lives on AirSyncBase from protocol 12.0 onward, never on the Calendar page.
        XCTAssertEqual(item.child(ASB.body)?.value(ASB.data),
                       "первая  строка\n\nвторая")
    }

    // MARK: Malformed input

    func testRejectsTruncatedDocument() {
        XCTAssertThrowsError(try WBXMLReader.parse(Data([0x03, 0x01])))
    }

    func testSurvivesBodyTruncatedMidString() throws {
        // Header plus an opened tag and an inline string with no terminator and no END.
        let bytes: [UInt8] = [0x03, 0x01, 0x6A, 0x00, 0x00, 0x07, 0x56, 0x52, 0x03, 0x61, 0x62]
        let tree = try WBXMLReader.parse(Data(bytes))
        XCTAssertEqual(tree.first(FH.syncKey)?.text, "ab")
    }

    func testOpaqueLengthBeyondBufferIsClamped() throws {
        // OPAQUE (0xC3) claiming 200 bytes with only 3 present must not read out of bounds.
        let bytes: [UInt8] = [0x03, 0x01, 0x6A, 0x00, 0x00, 0x07, 0x56, 0xC3, 0xC8, 0x01, 0x61, 0x62]
        XCTAssertNoThrow(try WBXMLReader.parse(Data(bytes)))
    }

    func testRepeatedPageSwitchesAreBoundedByMaximumDepth() {
        let header: [UInt8] = [0x03, 0x01, 0x6A, 0x00]
        let switches = Array(repeating: [UInt8(0x00), UInt8(0x07)], count: 128).flatMap { $0 }
        XCTAssertNoThrow(try WBXMLReader.parse(Data(header + switches)))
    }

    func testRepeatedEntitiesAreBoundedByMaximumDepth() {
        let header: [UInt8] = [0x03, 0x01, 0x6A, 0x00]
        let entities = Array(repeating: [UInt8(0x02), UInt8(0x01)], count: 128).flatMap { $0 }
        XCTAssertNoThrow(try WBXMLReader.parse(Data(header + entities)))
    }

    func testOversizedMultiByteValueCannotOverflowTheCursor() {
        let bytes: [UInt8] = [0x03, 0x01, 0x6A, 0x00, 0xC3]
            + Array(repeating: 0xFF, count: 32)
            + [0x7F]
        XCTAssertNoThrow(try WBXMLReader.parse(Data(bytes)))
    }
}
