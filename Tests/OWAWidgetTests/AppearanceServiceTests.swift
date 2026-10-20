import AppKit
import XCTest
@testable import OWAWidget

/// The app always sets an explicit look, "System" included, so the popover and the inbox panel
/// beside it never disagree.
final class AppearanceServiceTests: XCTestCase {
    func testSystemFollowsTheSystemSetting() {
        XCTAssertEqual(AppearanceService.appearanceName(for: .system, systemIsDark: true), .darkAqua)
        XCTAssertEqual(AppearanceService.appearanceName(for: .system, systemIsDark: false), .aqua)
    }

    func testFixedThemesIgnoreTheSystem() {
        for systemIsDark in [true, false] {
            XCTAssertEqual(AppearanceService.appearanceName(for: .light, systemIsDark: systemIsDark), .aqua)
            XCTAssertEqual(AppearanceService.appearanceName(for: .dark, systemIsDark: systemIsDark), .darkAqua)
        }
    }

    func testReadsTheCurrentSystemSetting() {
        let style = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String
        XCTAssertEqual(AppearanceService.systemIsDark(), style == "Dark")
    }
}
