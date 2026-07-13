import Foundation

/// In-place refresh for the open reading pane: when the store reloads from
/// the DB (`MailStore.threadContentVersion`), ThreadDetailView re-queries its
/// thread's header rows and merges them over what's on screen.
enum ThreadRefresh {

    /// True when a reading-pane message still needs a body fetch.
    static func needsBodyLoad(_ message: Message) -> Bool {
        message.bodyText.isEmpty && (message.bodyHTML == nil || message.bodyHTML?.isEmpty == true)
    }

    /// Fresh header rows win (labels/read state may have changed); bodies
    /// already hydrated in `current` are spliced back in so a refresh never
    /// collapses an open card to "Loading…". Messages gone from `fresh` are
    /// gone for real (e.g. a discarded draft).
    static func merge(current: [Message], fresh: [Message]) -> [Message] {
        let byId = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        return fresh.map { row in
            guard needsBodyLoad(row), let old = byId[row.id], !needsBodyLoad(old) else {
                return row
            }
            var merged = row
            merged.bodyText = old.bodyText
            merged.bodyHTML = old.bodyHTML
            return merged
        }
    }
}
