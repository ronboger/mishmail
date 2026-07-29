import Foundation
import GRDB

/// Category-tab exclusion for thread lists.
///
/// Extracted from `MailStore` so hostless unit tests share the exact SQL
/// (no AppKit) — same pattern as `SidebarCounts`. Hiding a category removes
/// unstarred mail in that tab; a star is an explicit pin and always survives.
///
/// `keepIds` are threads that were just unstarred under an active hide (or
/// other star-gated list). Under category hide, pins are thread-long (drop
/// when selection leaves); under Starred / is:starred they are session-long
/// (until view/filter change). See `StarStickiness`.
enum CategoryHide {
    /// Hide the given Gmail categories (`CATEGORY_PROMOTIONS`, …), keeping
    /// starred threads (and stickied `keepIds`) visible. Prefer denorm flags
    /// for promo/social; fall back to `labelIds LIKE` for Updates/Forums (no
    /// denorm columns yet).
    static func apply(
        _ query: QueryInterfaceRequest<MailThread>,
        hide: Set<String>,
        keepIds: [String] = []
    ) -> QueryInterfaceRequest<MailThread> {
        var q = query
        for cat in hide {
            switch cat {
            case "CATEGORY_PROMOTIONS":
                q = q.filter(Column("inPromotions") == false
                             || Column("isStarred") == true
                             || keepIds.contains(Column("id")))
            case "CATEGORY_SOCIAL":
                q = q.filter(Column("inSocial") == false
                             || Column("isStarred") == true
                             || keepIds.contains(Column("id")))
            default:
                q = q.filter(!Column("labelIds").like("%\(cat)%")
                             || Column("isStarred") == true
                             || keepIds.contains(Column("id")))
            }
        }
        return q
    }

    /// Legacy saved-view "Exclude Promotions & Social" structured field.
    /// Same starred / keepIds pin-through as `apply` for the promo+social pair.
    static func applyExcludePromotions(
        _ query: QueryInterfaceRequest<MailThread>,
        keepIds: [String] = []
    ) -> QueryInterfaceRequest<MailThread> {
        query.filter((Column("inPromotions") == false && Column("inSocial") == false)
                     || Column("isStarred") == true
                     || keepIds.contains(Column("id")))
    }
}
