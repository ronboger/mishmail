import Foundation
import SwiftUI
import AppKit
import GRDB

extension MailStore {
    // MARK: - On-device AI triage

    /// Loads the persisted category map once; after that the in-memory map is
    /// authoritative (classifyInbox updates it as it writes rows), so thread
    /// reloads don't re-read the table every time.
    func loadAICategories() async {
        if let existing = aiCategoriesLoad {
            await existing.value
            return
        }
        let task = Task { @MainActor in
            let pool = self.db
            let rows = (try? await pool.read { try ThreadAICategory.fetchAll($0) }) ?? []
            self.aiCategories = Dictionary(rows.map { ($0.threadId, $0.category) }) { _, last in last }
        }
        aiCategoriesLoad = task
        await task.value
    }

    /// Classifies the currently loaded threads into local AI buckets. Manual
    /// and sequential (a small local model), skipping already-classified
    /// threads. Results persist in their own table so sync never wipes them.
    func classifyInbox() {
        guard !classifying else { return }
        let targets = threads.filter { aiCategories[$0.id] == nil }
        guard !targets.isEmpty else {
            showNotice("All caught up — nothing new to sort.")
            return
        }
        classify(targets, quiet: false)
    }
    func autoClassifyNewMail() async {
        guard AITriage.isAutoClassifyEnabled(UserDefaults.standard) else { return }
        // Auto-sort is silent. A cloud triage model would upload every new
        // snippet; skip unless the assigned provider stays on this Mac or
        // on the LAN (RFC1918 / link-local Ollama).
        let resolved = LLMTaskRunner.resolve(.triage)
        if AITriage.shouldSkipSilentAutoSort(config: resolved?.config, model: resolved?.model) {
            return
        }
        if AITriage.isFailurePauseActive(pausedUntil: autoClassifyPausedUntil) {
            return
        }
        await loadAICategories()
        let pool = db
        let candidates = (try? await pool.read { db in
            try MailThread
                .filter(Column("inInbox") == true && Column("inTrash") == false)
                .order(Column("lastDate").desc).limit(100).fetchAll(db)
        }) ?? []
        classify(candidates.filter { aiCategories[$0.id] == nil }, quiet: true)
    }

    private func classify(_ targets: [MailThread], quiet: Bool) {
        guard !isShuttingDown, !classifying, !targets.isEmpty else { return }
        // One status write per classified thread republished the FilterBar
        // each time; throttle like sync progress (newest count still lands).
        let progress = makeSyncStatusSink("Sorting with AI…")
        classificationTask = Task {
            defer {
                endSyncStatus(progress)
                classificationTask = nil
            }
            var done = 0
            for thread in targets {
                guard !Task.isCancelled, !isShuttingDown else { return }
                let from = thread.participants.isEmpty ? thread.fromDisplay : thread.participants
                let prompt = LLMPrompts.classify(subject: thread.subject, from: from,
                                                 snippet: thread.snippet, categories: Classifier.categories)
                do {
                    let raw = try await LLMTaskRunner.generate(task: .triage, prompt: prompt)
                    try Task.checkCancellation()
                    let category = Classifier.normalize(raw)
                    try await db.write { database in
                        try ThreadAICategory(threadId: thread.id, category: category).save(database)
                    }
                    aiCategories[thread.id] = category
                    done += 1
                    progress.submit("Sorting with AI… \(done)/\(targets.count)")
                } catch {
                    guard !Task.isCancelled else { return }
                    if quiet {
                        autoClassifyPausedUntil = Date().addingTimeInterval(AITriage.failurePause)
                    } else {
                        showNotice(LLMTaskRunner.errorMessage(error, task: .triage))
                    }
                    return
                }
            }
            if !quiet {
                showNotice("Sorted \(done) thread\(done == 1 ? "" : "s") with AI.")
            }
        }
    }
}
