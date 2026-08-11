import XCTest
import AppKit
@testable import OWAWidget

/// Guards the text view configuration behind the meeting body. The panel gives the view an exact
/// height and expects it to stay put; AppKit's defaults do the opposite.
final class SelectableAttributedTextTests: XCTestCase {

    private func tallBody() -> NSAttributedString {
        let paragraphs = (1...40).map { "Пункт повестки номер \($0), достаточно длинный, чтобы перенестись" }
        return NSAttributedString(
            string: paragraphs.joined(separator: "\n"),
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        )
    }

    /// The regression: a self-resizing text view whose text does not fit the frame it was given
    /// grows itself and moves its origin, which showed up as the agenda sliding down the card
    /// behind a blank gap.
    func testTextViewKeepsTheFrameItWasGiven() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let textView = SelectableAttributedText.makeTextView()
        textView.frame = host.bounds
        host.addSubview(textView)

        textView.textStorage?.setAttributedString(tallBody())
        let container = try XCTUnwrap(textView.textContainer)
        textView.layoutManager?.ensureLayout(for: container)
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(textView.frame, host.bounds)
        // Sanity: the text really is taller than the frame, so a resizing view would have moved.
        let used = try XCTUnwrap(textView.layoutManager?.usedRect(for: container))
        XCTAssertGreaterThan(used.height, host.bounds.height)
    }

    func testTextViewIsReadOnlyButSelectable() {
        let textView = SelectableAttributedText.makeTextView()

        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isVerticallyResizable)
        XCTAssertFalse(textView.isHorizontallyResizable)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, 0)
        XCTAssertEqual(textView.textContainerInset, .zero)
        // Link styling comes from the attributed string; the view must not add its own.
        XCTAssertTrue(textView.linkTextAttributes?.isEmpty ?? true)
    }
}
