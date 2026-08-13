import Foundation

enum LLMUsageLog {
    /// One summary row per task over the window.
    struct TaskSpend: Equatable {
        var task: LLMTask
        var promptTokens: Int
        var completionTokens: Int
        var estimatedUSD: Double?   // nil when any row's model has no price
    }

    private struct Aggregate {
        var task: LLMTask
        var promptTokens = 0
        var completionTokens = 0
        var estimatedUSD = 0.0
        var hasUnknownPrice = false
    }

    static func summarize(rows: [LLMUsageRow], since: Date,
                          overrides: [String: LLMPrice]) -> [TaskSpend] {
        var aggregates: [String: Aggregate] = [:]

        for row in rows where row.createdAt >= since {
            guard let task = LLMTask(rawValue: row.task) else { continue }
            var aggregate = aggregates[task.rawValue] ?? Aggregate(task: task)
            aggregate.promptTokens += row.promptTokens
            aggregate.completionTokens += row.completionTokens
            if let price = LLMPricing.price(model: row.model, overrides: overrides) {
                aggregate.estimatedUSD += LLMPricing.cost(
                    usage: LLMUsage(promptTokens: row.promptTokens,
                                    completionTokens: row.completionTokens),
                    price: price)
            } else {
                aggregate.hasUnknownPrice = true
            }
            aggregates[task.rawValue] = aggregate
        }

        return LLMTask.allCases.compactMap { task in
            guard let aggregate = aggregates[task.rawValue] else { return nil }
            return TaskSpend(task: aggregate.task,
                             promptTokens: aggregate.promptTokens,
                             completionTokens: aggregate.completionTokens,
                             estimatedUSD: aggregate.hasUnknownPrice
                                ? nil : aggregate.estimatedUSD)
        }
    }

    static func row(task: LLMTask, config: LLMProviderConfig, model: String,
                    usage: LLMUsage, now: Date) -> LLMUsageRow {
        LLMUsageRow(id: UUID().uuidString, task: task.rawValue,
                    providerID: config.id.uuidString, model: model,
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens, createdAt: now)
    }
}
