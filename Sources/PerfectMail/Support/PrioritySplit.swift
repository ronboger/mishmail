import Foundation

/// Splits a thread list into the pinned Priority section — threads that are
/// starred or carry Gmail's IMPORTANT label — and everything else, preserving
/// the incoming (date-sorted) order. Gmail computes IMPORTANT itself, so the
/// split needs no local AI.
enum PrioritySplit {
    static func partition(_ threads: [MailThread],
                          enabled: Bool) -> (priority: [MailThread], rest: [MailThread]) {
        guard enabled else { return ([], threads) }
        var priority: [MailThread] = []
        var rest: [MailThread] = []
        for thread in threads {
            if thread.isStarred || thread.labels.contains("IMPORTANT") {
                priority.append(thread)
            } else {
                rest.append(thread)
            }
        }
        return (priority, rest)
    }
}
