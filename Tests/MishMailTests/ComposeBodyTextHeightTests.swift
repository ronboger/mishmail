import AppKit
import XCTest

/// The compose card sizes the body from the text view's real layout, not
/// from a character-count estimate.
@MainActor
final class ComposeBodyTextHeightTests: XCTestCase {
    private func makeTextView(width: CGFloat, fontSize: CGFloat,
                              string: String) -> NSTextView {
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.font = .systemFont(ofSize: fontSize)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.string = string
        return textView
    }

    func testWrappedLargeFontBodyMeasuresMoreThanTheEstimate() throws {
        // The body from the bug report: six logical lines, one of which wraps.
        let body = "Thanks  for the intro (moving you to bcc)!\n\nIt's great to meet you , "
            + "let's chat. What are some times that work for you in the coming weeks?"
            + "\n\nBest,\nRon"
        let textView = makeTextView(width: 590, fontSize: 20, string: body)
        let height = try XCTUnwrap(ComposeBodyLayout.textHeight(of: textView))
        let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 20))
        XCTAssertGreaterThanOrEqual(height, 7 * lineHeight - 1)
        // The old estimate: fewer and shorter lines than the real layout.
        XCTAssertGreaterThan(
            ComposeBodyLayout.contentHeight(measuredTextHeight: height),
            ComposeBodyLayout.contentHeight(body: body))
    }

    func testNarrowerWidthMeasuresTallerText() throws {
        let body = String(repeating: "word ", count: 60)
        let wide = try XCTUnwrap(ComposeBodyLayout.textHeight(
            of: makeTextView(width: 600, fontSize: 14, string: body)))
        let narrow = try XCTUnwrap(ComposeBodyLayout.textHeight(
            of: makeTextView(width: 300, fontSize: 14, string: body)))
        XCTAssertGreaterThan(narrow, wide)
    }

    func testTrailingNewlineCountsItsEmptyLine() throws {
        let one = try XCTUnwrap(ComposeBodyLayout.textHeight(
            of: makeTextView(width: 400, fontSize: 14, string: "Hi")))
        let two = try XCTUnwrap(ComposeBodyLayout.textHeight(
            of: makeTextView(width: 400, fontSize: 14, string: "Hi\n")))
        XCTAssertGreaterThan(two, one)
    }

    func testNoWidthYetMeasuresNothing() {
        XCTAssertNil(ComposeBodyLayout.textHeight(
            of: makeTextView(width: 0, fontSize: 14, string: "Hi")))
    }
}
