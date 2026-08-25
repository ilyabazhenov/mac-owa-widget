import XCTest
@testable import OWAWidget

/// Регрессия: многодневная встреча (отпуск на неделю) показывала countdown как «2 464 мин» —
/// счётчик не переходил через границу часа и суток.
final class CompactDurationTests: XCTestCase {
    func testUnderHourStaysInMinutes() {
        XCTAssertEqual(CompactDuration.breakdown(minutes: 0), .minutes(0))
        XCTAssertEqual(CompactDuration.breakdown(minutes: 45), .minutes(45))
        XCTAssertEqual(CompactDuration.breakdown(minutes: 59), .minutes(59))
    }

    func testHourBoundarySwitchesToHours() {
        XCTAssertEqual(CompactDuration.breakdown(minutes: 60), .hoursMinutes(hours: 1, minutes: 0))
        XCTAssertEqual(CompactDuration.breakdown(minutes: 200), .hoursMinutes(hours: 3, minutes: 20))
        XCTAssertEqual(CompactDuration.breakdown(minutes: 1_439), .hoursMinutes(hours: 23, minutes: 59))
    }

    func testDayBoundarySwitchesToDays() {
        XCTAssertEqual(CompactDuration.breakdown(minutes: 1_440), .daysHours(days: 1, hours: 0))
        XCTAssertEqual(CompactDuration.breakdown(minutes: 2_464), .daysHours(days: 1, hours: 17))
        XCTAssertEqual(CompactDuration.breakdown(minutes: 7 * 24 * 60 + 90), .daysHours(days: 7, hours: 1))
    }

    func testNegativeInputClampsToZero() {
        XCTAssertEqual(CompactDuration.breakdown(minutes: -10), .minutes(0))
    }
}
