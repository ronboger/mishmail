import AppKit
import XCTest

/// Return in a compose body that hugs its text must not scroll the clip
/// view for the one runloop turn before SwiftUI grows the editor.
@MainActor
final class ComposeBodyCaretScrollTests: XCTestCase {
    private func makeEditor(height: CGFloat, lines: Int)
        -> (NSScrollView, ComposeCaretSettlingTextView, NSWindow) {
        let scroll = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 400, height: height))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = ComposeCaretSettlingTextView(
            frame: NSRect(x: 0, y: 0, width: 400, height: height))
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = .zero
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(scroll)
        textView.string = Array(repeating: "line", count: lines)
            .joined(separator: "\n")
        textView.setSelectedRange(
            NSRange(location: (textView.string as NSString).length, length: 0))
        return (scroll, textView, window)
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Height of `lines` lines of body text, plus a few points of slack.
    private func fittingHeight(lines: Int) -> CGFloat {
        let line = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 14))
        return CGFloat(lines) * line + 4
    }

    func testReturnDoesNotScrollWhenTheEditorGrowsToFit() {
        let (scroll, textView, window) = makeEditor(
            height: fittingHeight(lines: 5), lines: 5)
        _ = window
        textView.insertNewline(nil)
        // The document is now one line taller than the clip.
        XCTAssertGreaterThan(textView.frame.height, scroll.contentView.bounds.height)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        // SwiftUI applies the reported height.
        scroll.setFrameSize(NSSize(width: 400, height: fittingHeight(lines: 6)))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        wait(ComposeCaretSettlingTextView.caretScrollSettleDelay * 3)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }

    func testReturnFollowsTheCaretWhenTheEditorIsHeightCapped() {
        let (scroll, textView, window) = makeEditor(
            height: fittingHeight(lines: 5), lines: 5)
        _ = window
        textView.insertNewline(nil)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 0.5)
        // No resize comes: the caret is followed after the settle delay.
        wait(ComposeCaretSettlingTextView.caretScrollSettleDelay * 3)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 1)
    }

    func testScrolledEditorFollowsTheCaretImmediately() {
        let (scroll, textView, window) = makeEditor(
            height: fittingHeight(lines: 5), lines: 12)
        _ = window
        textView.scrollRangeToVisible(textView.selectedRange())
        wait(ComposeCaretSettlingTextView.caretScrollSettleDelay * 3)
        let scrolled = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(scrolled, 1)
        textView.insertNewline(nil)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, scrolled + 1)
    }
}
