import Foundation

/// Which row should be selected after removing one from a list — the row
/// below it, or the one above when the removed row was last (Gmail-style
/// auto-advance after archive/trash).
enum SelectionAdvance {
    static func neighborId(in ids: [String], removing id: String) -> String? {
        guard let idx = ids.firstIndex(of: id) else { return nil }
        if idx + 1 < ids.count { return ids[idx + 1] }
        return idx > 0 ? ids[idx - 1] : nil
    }
}
