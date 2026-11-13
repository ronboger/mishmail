import AppKit
import XCTest

/// `ensureLayout` can raise NSRangeException. Uncaught, it unwinds through
/// SwiftUI's update frames and corrupts Observation tracking (crash on the
/// next @Observable read). The measurement must absorb it.
final class SafeTextLayoutTests: XCTestCase {
    private final class RaisingLayoutManager: NSLayoutManager {
        override func ensureLayout(for container: NSTextContainer) {
            NSException(name: .rangeException,
                        reason: "test: glyph range out of bounds").raise()
        }
    }

    private func makeTextView(_ lm: NSLayoutManager) -> NSTextView {
        let storage = NSTextStorage(string: "one\ntwo\nthree")
        let container = NSTextContainer(
            size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        lm.addTextContainer(container)
        storage.addLayoutManager(lm)
        return NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100),
                          textContainer: container)
    }

    func testLayoutExceptionIsCaught() {
        let lm = RaisingLayoutManager()
        let textView = makeTextView(lm)
        XCTAssertFalse(MMEnsureTextLayout(lm, textView.textContainer!))
    }

    func testTextHeightIsNilWhenLayoutRaises() {
        let textView = makeTextView(RaisingLayoutManager())
        XCTAssertNil(ComposeBodyLayout.textHeight(of: textView))
    }

    func testTextHeightMeasuresWhenLayoutSucceeds() {
        let lm = NSLayoutManager()
        let textView = makeTextView(lm)
        XCTAssertTrue(MMEnsureTextLayout(lm, textView.textContainer!))
        let height = ComposeBodyLayout.textHeight(of: textView)
        XCTAssertNotNil(height)
        XCTAssertGreaterThan(height ?? 0, 30)
    }
}
