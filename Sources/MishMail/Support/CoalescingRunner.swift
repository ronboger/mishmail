import Foundation

/// Runs one operation at a time and coalesces callers that arrive while it
/// is in flight into at most one follow-up run.
///
/// A plain single-flight join hands a late caller the result of a pass that
/// started before its change (a save, a sent message, a queued edit), so the
/// change stays invisible until the next poll. Here a caller that finds a pass
/// running waits for the *next* pass instead. Every caller that arrives while
/// that follow-up is still queued shares it, so a burst of requests costs at
/// most one extra pass.
///
/// Cancellation: the caller that started a running pass is its only waiter,
/// so its cancellation cancels that pass. A queued follow-up is shared, and
/// no waiter's cancellation cancels it; only `cancelAll()` does.
actor CoalescingRunner<Value: Sendable> {
    typealias Operation = @Sendable () async throws -> Value

    private struct Pass {
        let id: UUID
        let task: Task<Value, Error>
    }
    private var running: Pass?
    private var queued: Pass?

    /// True when no pass is running or queued.
    var isIdle: Bool { running == nil && queued == nil }

    /// Runs `operation`, or joins the follow-up pass when one is running.
    /// The operation passed by a joiner is used only when that joiner is the
    /// one that queues the follow-up; later joiners share it as is.
    func run(_ operation: @escaping Operation) async throws -> Value {
        if let queued {
            return try await queued.task.value
        }
        if let running {
            let id = UUID()
            let previous = running.task
            let task = Task<Value, Error> {
                // The follow-up must start after the pass it follows, whatever
                // that pass's outcome.
                _ = try? await previous.value
                self.promote(id)
                return try await self.execute(id, operation: {
                    try Task.checkCancellation()
                    return try await operation()
                })
            }
            queued = Pass(id: id, task: task)
            return try await task.value
        }
        let id = UUID()
        let task = Task<Value, Error> {
            try await self.execute(id, operation: operation)
        }
        running = Pass(id: id, task: task)
        // An unstructured task does not inherit the caller's cancellation.
        // Forward it: this caller is the pass's only waiter.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancels the running and queued passes and waits until both end.
    func cancelAll() async {
        let tasks = [running, queued].compactMap { $0?.task }
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
    }

    /// Runs the pass and clears it before its task completes, so a caller
    /// that arrives afterwards never joins a pass that already ended.
    private func execute(_ id: UUID, operation: Operation) async throws -> Value {
        defer { finish(id) }
        return try await operation()
    }

    /// The queued pass becomes the running one once its predecessor ends.
    private func promote(_ id: UUID) {
        guard let next = queued, next.id == id else { return }
        running = next
        queued = nil
    }

    private func finish(_ id: UUID) {
        guard running?.id == id else { return }
        running = nil
    }
}
