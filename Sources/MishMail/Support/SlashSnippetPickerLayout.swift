import CoreGraphics
import Foundation

/// Layout math for the compose `/` snippet picker. Kept pure so a height-
/// constrained reply card (inline compose + collapsed quote Spacer) can't
/// silently collapse the list to zero while the chrome still shows.
enum SlashSnippetPickerLayout {
    /// Cap so a long match list scrolls instead of eating the whole card.
    /// Kept under ~7 rows so the picker + chrome still fit the shortest
    /// comfortable inline reply card (~320pt) with From/To/Subject present.
    static let maxListHeight: CGFloat = 160
    /// One row: ~15pt line of 12pt text + vertical padding 4×2 + spacing 1.
    static let rowHeight: CGFloat = 24
    /// Inner padding around the LazyVStack (4 top + 4 bottom).
    static let listPadding: CGFloat = 8

    /// Fixed height for the match list. Using only `maxHeight` lets SwiftUI
    /// compress a ScrollView to 0 when the parent VStack is short — the
    /// picker header/footer still render (the bug in replies) but rows
    /// vanish. A definite height keeps rows visible; Spacer yields first.
    static func listHeight(snippetCount: Int) -> CGFloat {
        guard snippetCount > 0 else { return 0 }
        let content = CGFloat(snippetCount) * rowHeight + listPadding
        return min(content, maxListHeight)
    }
}
