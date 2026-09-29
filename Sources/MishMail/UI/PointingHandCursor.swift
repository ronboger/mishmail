import AppKit
import SwiftUI

/// Keeps AppKit's cursor stack balanced when a hovered view disappears.
struct PointingHandCursorModifier: ViewModifier {
    let enabled: Bool
    @State private var cursorPushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, enabled, !cursorPushed {
                    NSCursor.pointingHand.push()
                    cursorPushed = true
                } else if (!inside || !enabled), cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onChange(of: enabled) { _, enabled in
                if !enabled, cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
            .onDisappear {
                if cursorPushed {
                    NSCursor.pop()
                    cursorPushed = false
                }
            }
    }
}

extension View {
    func pmPointingHandCursor(enabled: Bool = true) -> some View {
        modifier(PointingHandCursorModifier(enabled: enabled))
    }
}
