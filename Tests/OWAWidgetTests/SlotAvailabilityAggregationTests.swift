import XCTest
@testable import OWAWidget

/// Aggregates attendee availability into one grid-cell state.
///
/// Codes come from Exchange merged free/busy: `0` free, `1` tentative, `2` busy,
/// `3` out of office, and `4` no data. The first four form a severity scale; the fifth does not.
/// This distinction once broke rendering: `"4"` is lexically greater than `"3"`, so one attendee
/// without published availability could override genuinely busy attendees.
final class SlotAvailabilityAggregationTests: XCTestCase {

    private func isFree(_ state: SlotAvailabilityState) -> Bool {
        if case .free = state { return true }
        return false
    }

    // MARK: Regular scale

    func testWorstStatusWins() {
        XCTAssertTrue(isFree(SlotAvailabilityState.aggregate(from: ["0", "0", "0"])))

        if case .tentative = SlotAvailabilityState.aggregate(from: ["0", "1"]) {} else {
            XCTFail("под вопросом должно перевесить свободен")
        }
        if case .busy = SlotAvailabilityState.aggregate(from: ["0", "1", "2"]) {} else {
            XCTFail("занят должен перевесить всё, кроме отсутствия")
        }
        if case .outOfOffice = SlotAvailabilityState.aggregate(from: ["0", "2", "3"]) {} else {
            XCTFail("вне офиса — худший из известных")
        }
    }

    func testEmptyInputIsFree() {
        XCTAssertTrue(isFree(SlotAvailabilityState.aggregate(from: [])))
    }

    // MARK: “No data” code

    /// The original bug: a colleague without published availability made a slot green even when
    /// another attendee was genuinely busy.
    func testNoDataDoesNotMaskABusyAttendee() {
        if case .busy = SlotAvailabilityState.aggregate(from: ["2", "4"]) {} else {
            XCTFail("«нет данных» не должно перекрывать занятость")
        }
        if case .busy = SlotAvailabilityState.aggregate(from: ["4", "4", "2", "4"]) {} else {
            XCTFail("сколько бы ни было неизвестных, занятый остаётся занятым")
        }
        if case .outOfOffice = SlotAvailabilityState.aggregate(from: ["4", "3"]) {} else {
            XCTFail("«нет данных» не должно перекрывать отсутствие в офисе")
        }
        if case .tentative = SlotAvailabilityState.aggregate(from: ["4", "1", "0"]) {} else {
            XCTFail("«нет данных» не должно перекрывать «под вопросом»")
        }
    }

    /// When nobody has published availability, there is no known status. The cell appears free
    /// but stays non-clickable: the calculator requires exactly `"0"` and will not offer it.
    func testAllUnknownFallsBackToFree() {
        XCTAssertTrue(isFree(SlotAvailabilityState.aggregate(from: ["4", "4", "4"])))
    }

    /// Unknown codes from future protocol versions must not behave as busy.
    func testUnknownCodesAreTreatedAsFreeNotAsBusy() {
        XCTAssertTrue(isFree(SlotAvailabilityState.aggregate(from: ["0", "9"])))
    }
}
