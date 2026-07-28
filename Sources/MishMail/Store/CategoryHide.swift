import Foundation
import GRDB

/// Category-tab exclusion for thread lists.
///
/// Extracted from `MailStore` so hostless unit tests share the exact SQL
/// (no AppKit) — same pattern as `SidebarCounts`. Hiding a category removes
/// unstarred mail in that tab; a star is an explicit pin and always survives.
enum CategoryHide {
    /// Hide the given Gmail categories (`CATEGORY_PROMOTIONS`, …), keeping
    /// starred threads visible. Prefer denorm flags for promo/social; fall
    /// back to `labelIds LIKE` for Updates/Forums (no denorm columns yet).
    static func apply(
        _ query: QueryInterfaceRequest<MailThread>,
        hide: Set<String>
    ) -> QueryInterfaceRequest<MailThread> {
        var q = query
        for cat in hide {
            switch cat {
            case "CATEGORY_PROMOTIONS":
                q = q.filter(Column("inPromotions") == false || Column("isStarred") == true)
            case "CATEGORY_SOCIAL":
                q = q.filter(Column("inSocial") == false || Column("isStarred") == true)
            default:
                q = q.filter(!Column("labelIds").like("%\(cat)%") || Column("isStarred") == true)
            }
        }
        return q
    }

    /// Legacy saved-view "Exclude Promotions & Social" structured field.
    /// Same starred pin-through as `apply` for the promo+social pair.
    static func applyExcludePromotions(
        _ query: QueryInterfaceRequest<MailThread>
    ) -> QueryInterfaceRequest<MailThread> {
        query.filter((Column("inPromotions") == false && Column("inSocial") == false)
                     || Column("isStarred") == true)
    }
}
