import XCTest
@testable import OWAWidget

final class UpdateCheckServiceTests: XCTestCase {
    func testComparePatchVersions() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.9", "1.0.10"),
            .orderedAscending
        )
    }

    func testCompareEqualVersions() {
        XCTAssertEqual(UpdateVersionComparison.compare("1.0.23", "1.0.23"), .orderedSame)
    }

    func testNormalizeLeadingV() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.23", "v1.0.24"),
            .orderedAscending
        )
    }

    func testMinorGreaterThanPatch() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.99", "1.1.0"),
            .orderedAscending
        )
    }

    func testPaddingMissingZeros() {
        XCTAssertEqual(UpdateVersionComparison.compare("1.0", "1.0.0"), .orderedSame)
    }

    func testPrereleaseSuffixOlderThanRelease() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.10-rc", "1.0.10"),
            .orderedAscending
        )
    }

    func testReleaseNewerThanPrereleaseSameNumeric() {
        XCTAssertEqual(
            UpdateVersionComparison.compare("1.0.10", "1.0.10-rc"),
            .orderedDescending
        )
    }

    func testGarbageVersionsAreSame() {
        XCTAssertEqual(UpdateVersionComparison.compare("foo", "bar"), .orderedSame)
    }

    func testNormalizeTrimsAndStripsV() {
        XCTAssertEqual(UpdateVersionComparison.normalize("  v1.2.3  "), "1.2.3")
    }
}
