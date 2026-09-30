import Foundation

/// Runs async work over many items with a cap on how many run at once per
/// lane (for bulk thread edits, a lane is an account). Lanes run side by
/// side; inside a lane, items start in input order and at most
/// `maxInFlight` are outstanding. Returns when every item has finished.
///
/// Why lanes rather than one global cap: each account has its own Gmail
/// client and quota bucket, so one account's backlog should not hold back
/// another's calls.
enum BoundedLanes {
    static func run<Item: Sendable>(
        _ items: [Item],
        maxInFlight: Int,
        lane: (Item) -> String,
        body: @escaping @Sendable (Item) async -> Void
    ) async {
        guard !items.isEmpty else { return }
        let limit = max(1, maxInFlight)
        var order: [String] = []
        var lanes: [String: [Item]] = [:]
        for item in items {
            let key = lane(item)
            if lanes[key] == nil { order.append(key) }
            lanes[key, default: []].append(item)
        }
        await withTaskGroup(of: Void.self) { outer in
            for key in order {
                let laneItems = lanes[key] ?? []
                outer.addTask {
                    await withTaskGroup(of: Void.self) { group in
                        var next = 0
                        // Prime the window, then start one item per finish.
                        while next < min(limit, laneItems.count) {
                            let item = laneItems[next]
                            group.addTask { await body(item) }
                            next += 1
                        }
                        while await group.next() != nil {
                            guard next < laneItems.count else { continue }
                            let item = laneItems[next]
                            group.addTask { await body(item) }
                            next += 1
                        }
                    }
                }
            }
        }
    }
}
