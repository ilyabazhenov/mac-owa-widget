import XCTest
@testable import OWAWidget

/// A refusal with the expected machine code: the text alone is for the model, the code is the
/// contract with clients.
func XCTAssertRefusal(
    _ result: MCPToolResult,
    _ code: MCPErrorCode,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertTrue(result.isError, message(), file: file, line: line)
    XCTAssertEqual(result.errorCode, code, "\(message()) — \(result.errorMessage ?? "")", file: file, line: line)
}

extension MCPConfirmationOutcome {
    /// The code a meeting tool refuses with after this panel outcome.
    var refusalCode: MCPErrorCode {
        switch self {
        case .timedOut: .confirmationTimeout
        case .cancelled: .cancelled
        default: .userDeclined
        }
    }
}
