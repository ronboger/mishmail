import Foundation
import GRDB

/// Deterministic Priority candidate fetch, independent of the list page window.
///
/// The inbox list page is a date-desc window (`ThreadListPaging.pageSize`).
/// `PrioritySplit` only sees that page, so hiding a category (which shrinks
/// the unstarred set) used to pull older stars into the page and hoist them.
/// Fetching candidates with their own capped query keeps the Priority set
/// stable across category-hide toggles.
///
/// Hostless (no AppKit) — same pattern as `CategoryHide` / `SidebarCounts`.
enum PriorityCandidates {
    /// Bound when `maxCount` is uncapped (`PrioritySplit.cap` is nil).
    static let uncappedFetchLimit = 200

    /// Normalize the SQL fetch limit: positive cap → that many; `<= 0` → hard bound.
    static func fetchLimit(maxCount: Int) -> Int {
        PrioritySplit.cap(maxCount) ?? uncappedFetchLimit
    }

    /// Priority candidates for `mode` on an already-filtered list request
    /// (base + widen + chips + account). Returns `nil` for modes that do not
    /// need a separate candidate query (`.off`, `.vips` — VIP pins stay on
    /// the page + `vipThreadIds`).
    ///
    /// - `.starred`: starred only; `lastDate >= newerThan` when set.
    /// - `.starredImportant`: starred, or IMPORTANT within the window and not
    ///   sitting in a hidden category (IMPORTANT-only; stars always qualify).
    ///   Hidden membership matches `PrioritySplit` / `CategoryHide` (denorm
    ///   promo/social; `labelIds LIKE` for Updates/Forums).
    static func request(
        _ base: QueryInterfaceRequest<MailThread>,
        mode: PrioritySplit.Mode,
        hiddenCategories: Set<String> = [],
        newerThan: Date? = nil,
        maxCount: Int = 0,
        inboundSort: Bool = true
    ) -> QueryInterfaceRequest<MailThread>? {
        var q: QueryInterfaceRequest<MailThread>
        switch mode {
        case .off, .vips:
            return nil
        case .starred:
            q = base.filter(Column("isStarred") == true)
        case .starredImportant:
            q = applyStarredImportantFilter(base, hiddenCategories: hiddenCategories)
        }
        if let newerThan {
            q = q.filter(Column("lastDate") >= newerThan)
        }
        let key = ThreadListPaging.sortDateSQL(inboundSort: inboundSort)
        return q.order(sql: "\(key) DESC, id DESC")
            .limit(fetchLimit(maxCount: maxCount))
    }

    /// Union `candidates` into `page` by thread id. Page rows win on conflict.
    /// Output stays sorted newest-first by the same key as the list query
    /// (`areInListOrder` is true when the first thread should appear before
    /// the second). Candidates already on the page are ignored.
    static func merge(
        page: [MailThread],
        candidates: [MailThread],
        areInListOrder: (MailThread, MailThread) -> Bool
    ) -> [MailThread] {
        if candidates.isEmpty { return page }
        let pageIds = Set(page.map(\.id))
        let extras = candidates.filter { !pageIds.contains($0.id) }
        if extras.isEmpty { return page }

        var result: [MailThread] = []
        result.reserveCapacity(page.count + extras.count)
        var i = 0
        var j = 0
        while i < page.count && j < extras.count {
            if areInListOrder(page[i], extras[j]) {
                result.append(page[i])
                i += 1
            } else {
                result.append(extras[j])
                j += 1
            }
        }
        if i < page.count { result.append(contentsOf: page[i...]) }
        if j < extras.count { result.append(contentsOf: extras[j...]) }
        return result
    }

    /// Merge using list sort: activity date DESC, then id DESC.
    static func merge(
        page: [MailThread],
        candidates: [MailThread],
        inboundSort: Bool = true
    ) -> [MailThread] {
        merge(page: page, candidates: candidates) { a, b in
            isInListOrder(a, b, inboundSort: inboundSort)
        }
    }

    /// True when `a` should appear before `b` under date DESC, id DESC.
    static func isInListOrder(_ a: MailThread, _ b: MailThread,
                              inboundSort: Bool = true) -> Bool {
        let da = ThreadListPaging.activityDate(of: a, inboundSort: inboundSort)
        let db = ThreadListPaging.activityDate(of: b, inboundSort: inboundSort)
        if da != db { return da > db }
        return a.id > b.id
    }

    // MARK: - Private

    /// `isStarred OR (exact IMPORTANT token AND not in a hidden category)`.
    /// IMPORTANT membership mirrors `labels.contains("IMPORTANT")` (space-
    /// separated tokens), not a bare substring (avoids `UNIMPORTANT`).
    private static func applyStarredImportantFilter(
        _ query: QueryInterfaceRequest<MailThread>,
        hiddenCategories: Set<String>
    ) -> QueryInterfaceRequest<MailThread> {
        let importantSQL = "(' ' || labelIds || ' ') LIKE '% IMPORTANT %'"
        var notHidden: [String] = []
        for cat in hiddenCategories {
            switch cat {
            case "CATEGORY_PROMOTIONS":
                notHidden.append("inPromotions = 0")
            case "CATEGORY_SOCIAL":
                notHidden.append("inSocial = 0")
            default:
                // Constant category ids (CATEGORY_UPDATES / FORUMS) — same as CategoryHide.
                notHidden.append("labelIds NOT LIKE '%\(cat)%'")
            }
        }
        if notHidden.isEmpty {
            return query.filter(sql: "isStarred = 1 OR (\(importantSQL))")
        }
        let visible = notHidden.joined(separator: " AND ")
        return query.filter(sql: """
            isStarred = 1 OR (
                (\(importantSQL)) AND (\(visible))
            )
            """)
    }
}
