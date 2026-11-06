import AppKit
import SwiftUI

/// Benchmark-only draw marker. The workflow injects this behind an actual inbox
/// row or body in both builds. No probe is compiled into the distributed app.
struct MailLatencyProbe: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> Marker { Marker(name: name) }
    func updateNSView(_ view: Marker, context: Context) {}

    final class Marker: NSView {
        private static var clickTime: TimeInterval?
        private static var reported: Set<String> = []
        private static let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            clickTime = ProcessInfo.processInfo.systemUptime
            return event
        }

        let name: String
        private weak var observedClip: NSClipView?
        private var lastY: CGFloat?
        private var wheelMonitor: Any?
        private var firstWheel: TimeInterval?
        init(name: String) {
            self.name = name
            super.init(frame: .zero)
            _ = Self.monitor
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard window?.isVisible == true, !visibleRect.isEmpty else { return }
            if name == "inbox" { record(name, since: 0) }
            else if let start = Self.clickTime { record(name, since: start) }
            if name == "long", observedClip == nil, let clip = enclosingScrollView?.contentView {
                observedClip = clip
                lastY = clip.bounds.minY
                clip.postsBoundsChangedNotifications = true
                // Arm only after the target body draws. Inbox scrolling to
                // locate a fixture must never start a message-scroll sample.
                wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                    if let self, self.firstWheel == nil, event.window === self.window {
                        self.firstWheel = ProcessInfo.processInfo.systemUptime
                    }
                    return event
                }
                NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                    name: NSView.boundsDidChangeNotification, object: clip)
            }
        }
        deinit {
            if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        }
        @objc private func scrolled() {
            guard let y = observedClip?.bounds.minY else { return }
            defer { lastY = y }
            guard let previous = lastY, abs(y - previous) > 0.5, let start = firstWheel else { return }
            record("scroll", since: start)
        }
        private func record(_ key: String, since start: Double) {
            guard Self.reported.insert(key).inserted else { return }
            let seconds = ProcessInfo.processInfo.systemUptime - start
            let token = ProcessInfo.processInfo.environment["MAIL_BENCH_TRIAL"] ?? ""
            let pasteboard = NSPasteboard(name: .init("mishmail.benchmark.\(key)"))
            pasteboard.clearContents()
            pasteboard.setString("\(token) \(seconds)", forType: .string)
        }
    }
}
