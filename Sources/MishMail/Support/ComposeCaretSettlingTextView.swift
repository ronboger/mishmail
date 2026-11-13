import AppKit

/// NSTextView whose caret-following scroll does not fight a SwiftUI frame
/// that hugs the text. Base class of the compose body text view; it lives
/// in Support so the unit tests can drive it.
class ComposeCaretSettlingTextView: NSTextView {
    /// `scrollRangeToVisible` (caret after Return) can nudge the clip view
    /// horizontally when document width and clip width disagree by a pixel —
    /// classic NSTextView "body jumps sideways while typing" failure mode.
    /// Pin origin.x so the body never drifts while typing newlines.
    ///
    /// Vertically: the editor's SwiftUI frame hugs the text, but the new
    /// height reaches SwiftUI one runloop turn after the edit. On Return the
    /// document is one line taller than the clip for that turn, so AppKit
    /// scrolled the clip down a line and snapped it back when the frame grew
    /// (the "Enter flickers the scroll" bug). A first scroll away from the
    /// top therefore waits for the frame to settle: if the frame grows there
    /// is nothing left to scroll; if the editor is height-capped the caret is
    /// followed a moment later. An editor that is already scrolled follows
    /// the caret immediately, as before.
    override func scrollRangeToVisible(_ charRange: NSRange) {
        guard let clip = enclosingScrollView?.contentView else {
            super.scrollRangeToVisible(charRange)
            return
        }
        let before = clip.bounds.origin.y
        super.scrollRangeToVisible(charRange)
        if !isFlushingCaretScroll, abs(before) < 0.5,
           clip.bounds.origin.y > before + 0.5 {
            var origin = clip.bounds.origin
            origin.y = before
            clip.setBoundsOrigin(origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
            deferCaretScroll()
        }
        pinHorizontalScroll()
    }

    /// Longest wait for SwiftUI to resize the editor before the caret is
    /// followed anyway (the height-capped case, where no resize comes).
    static let caretScrollSettleDelay: TimeInterval = 0.05
    private var hasDeferredCaretScroll = false
    private var isFlushingCaretScroll = false
    private var clipFrameObserver: NSObjectProtocol?

    private func deferCaretScroll() {
        guard !hasDeferredCaretScroll else { return }
        hasDeferredCaretScroll = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.caretScrollSettleDelay
        ) { [weak self] in
            self?.flushDeferredCaretScroll()
        }
    }

    /// Runs the held-back caret scroll against the settled frame.
    func flushDeferredCaretScroll() {
        guard hasDeferredCaretScroll else { return }
        hasDeferredCaretScroll = false
        isFlushingCaretScroll = true
        scrollRangeToVisible(selectedRange())
        isFlushingCaretScroll = false
    }

    /// The clip resizes when SwiftUI applies the new editor height: that is
    /// the moment the deferred scroll can be decided without a flicker.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
            self.clipFrameObserver = nil
        }
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        clipFrameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushDeferredCaretScroll() }
        }
    }

    deinit {
        if let clipFrameObserver {
            NotificationCenter.default.removeObserver(clipFrameObserver)
        }
    }

    override func layout() {
        super.layout()
        pinHorizontalScroll()
    }

    private func pinHorizontalScroll() {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        guard abs(clip.bounds.origin.x) > 0.01 else { return }
        var origin = clip.bounds.origin
        origin.x = 0
        clip.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(clip)
    }
}
