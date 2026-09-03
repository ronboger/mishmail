import Foundation
import Network

/// Reachability edge detector. The app never *blocks* on this — every Gmail
/// call still runs and classifies its own failure — but the satisfied edge is
/// the earliest moment to replay the offline queues instead of waiting up to
/// a full poll interval, and the unsatisfied edge lets the UI say "Offline"
/// before the first request times out.
@MainActor
final class ConnectivityMonitor {
    private let monitor = NWPathMonitor()
    private var started = false
    private(set) var isReachable = true
    /// Fired on the main actor whenever reachability flips.
    var onChange: (@MainActor (Bool) -> Void)?

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isReachable != reachable else { return }
                self.isReachable = reachable
                self.onChange?(reachable)
            }
        }
        monitor.start(queue: DispatchQueue(label: "mishmail.connectivity", qos: .utility))
    }

    func stop() {
        guard started else { return }
        started = false
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }
}
