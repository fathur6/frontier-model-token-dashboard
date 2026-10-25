import Foundation
import SQLite3
#if canImport(OpencodeWidgetShared)
import OpencodeWidgetShared
#endif

typealias OpenAIUsageSource = LocalUsageSource

struct OpenAIUsageSample: Sendable {
    let hour: Date
    let modelID: String
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteTokens: Int64
    let outputTokens: Int64
    let source: OpenAIUsageSource
    let sessionID: String

    init(hour: Date, modelID: String, inputTokens: Int64, cachedInputTokens: Int64, cacheWriteTokens: Int64, outputTokens: Int64, source: OpenAIUsageSource, sessionID: String) {
        self.hour = Date(timeIntervalSince1970: floor(hour.timeIntervalSince1970 / 3_600) * 3_600)
        self.modelID = modelID
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.source = source
        self.sessionID = sessionID
    }
}

struct OpenAIHourlyTotal: Sendable, Equatable {
    let inputTokens: Int
    /// nil means at least one contributing model is unpriced, not zero cost.
    let estimatedCostUSD: Double?
}

/// Compatibility adapter; the live ledger consumes one LocalUsageSnapshot for
/// both providers, avoiding duplicated client reads and source-level ambiguity.
struct OpenAIUsageCollector: Sendable {
    private var reader: LocalUsageReader

    init(now: Date = Date(),
         openCodeDatabasePath: String = "\(NSHomeDirectory())/.local/share/opencode/opencode.db",
         hermesDatabasePath: String = "\(NSHomeDirectory())/.hermes/state.db",
         codexRoots: [URL] = [URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/sessions"), URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/archived_sessions")],
         codexSessionFiles: (@Sendable (URL) -> [URL]?)? = nil,
         databaseStep: @escaping @Sendable (OpaquePointer?) -> Int32 = sqlite3_step) {
        reader = LocalUsageReader(now: now, openCodeDatabasePath: openCodeDatabasePath, hermesDatabasePath: hermesDatabasePath, codexRoots: codexRoots)
        if let codexSessionFiles { reader.codexSessionFiles = codexSessionFiles }
        reader.databaseStep = databaseStep
    }

    func hourlyTotals() -> [Date: OpenAIHourlyTotal]? {
        let snapshot = reader.fetch()
        guard snapshot.anyAvailable, !snapshot.hasFailures else { return nil }
        return Self.totals(snapshot.observations)
    }

    static func totals(_ observations: [LocalUsageObservation]) -> [Date: OpenAIHourlyTotal] {
        var totals: [Date: OpenAIHourlyTotal] = [:]
        for observation in observations where observation.provider == .openAI {
            let previous = totals[observation.hour]
            let cost: Double?
            if let price = observation.estimatedCostUSD, previous == nil || previous?.estimatedCostUSD != nil {
                cost = (previous?.estimatedCostUSD ?? 0) + price
            } else { cost = nil }
            totals[observation.hour] = OpenAIHourlyTotal(inputTokens: (previous?.inputTokens ?? 0) + observation.tokens, estimatedCostUSD: cost)
        }
        return totals
    }

    static func aggregate(_ samples: [OpenAIUsageSample]) -> [Date: OpenAIHourlyTotal] {
        let observations = samples.enumerated().map { index, sample in
            let values = [sample.inputTokens, sample.cachedInputTokens, sample.cacheWriteTokens, sample.outputTokens].map { max(0, $0) }
            return LocalUsageObservation(source: sample.source, id: String(index), provider: .openAI,
                sessionID: sample.sessionID, hour: sample.hour, tokens: Int(values[0]),
                estimatedCostUSD: LocalUsageReader.estimatedCost(model: sample.modelID, values: values))
        }
        return totals(LocalUsageSnapshot.deduplicated(observations))
    }
}
