import CoreGraphics
import Foundation

/// Pure layout contract for the compose footer (documented + unit-tested).
///
/// The live SwiftUI structure in `ComposeView` enforces this with a left
/// cluster (`.frame(minWidth: 0).clipped()`, layoutPriority 0) and a right
/// cluster (`.fixedSize()`, layoutPriority 1). These helpers encode the same
/// numbers for regression tests — they are not called from the view.
///
/// The footer packs many fixed-size controls (Snippets, format bar, draft
/// status, Send). On a normal card those together exceed the inner width once
/// "Draft not saved" is permanently reserved. Without a priority split, the
/// HStack's ideal width overflows and `.frame(alignment: .topLeading)` +
/// `clipShape` cuts the **trailing** edge — draft status mid-word and the
/// Send button vanish (the screenshot bug).
///
/// Contract: the right cluster (status + trash + Send) always gets its ideal
/// width; left tools receive only the remainder and may clip. Status sits
/// left of trash so trash stays adjacent to Send (not separated by the
/// reserved idle status hole).
enum ComposeFooterLayout {
    /// Leading→trailing order of the right cluster in `ComposeView`.
    /// Status is reserved-width but must sit *before* trash so trash stays
    /// adjacent to Send (status-between them left an idle empty gap).
    static let rightClusterOrder = ["status", "trash", "send"]

    /// Width left for attach / snippets / AI / format tools after the right
    /// cluster claims its ideal size. Never negative.
    static func leftToolsMaxWidth(cardInnerWidth: CGFloat,
                                  rightClusterWidth: CGFloat) -> CGFloat {
        max(0, cardInnerWidth - max(0, rightClusterWidth))
    }

    /// Right cluster stays fully on-screen whenever the card can fit it.
    static func rightClusterFits(cardInnerWidth: CGFloat,
                                 rightClusterWidth: CGFloat) -> Bool {
        guard rightClusterWidth > 0 else { return true }
        return cardInnerWidth + 0.5 >= rightClusterWidth
    }

    /// Trash must sit immediately before Send in the right cluster (no
    /// reserved status hole between them).
    static func trashAdjacentToSend() -> Bool {
        guard let trash = rightClusterOrder.firstIndex(of: "trash"),
              let send = rightClusterOrder.firstIndex(of: "send") else {
            return false
        }
        return send == trash + 1
    }
}
