import Foundation
#if canImport(OpencodeWidgetShared)
import OpencodeWidgetShared
#endif

typealias UsageProvider = LocalUsageProvider

struct UsageTokenEvent: Sendable {
    let provider: UsageProvider
    let timestamp: Date
    let inputTokens: Int64
}

struct UsageHistoryResult: Sendable {
    let buckets: [HourlyUsageBucket]
    let anySourceReadable: Bool
}

/// Compatibility projection. The live ledger uses the same reader, retaining
/// source provenance so a partial refresh cannot erase historical usage.
struct UsageHistoryFetcher: Sendable {
    static let bucketCount = DeepSeekBalanceHistory.maximumHours
    private let reader: LocalUsageReader

    init(now: Date = Date(),
         openCodeDatabasePath: String = "\(NSHomeDirectory())/.local/share/opencode/opencode.db",
         hermesDatabasePath: String = "\(NSHomeDirectory())/.hermes/state.db",
         codexRoots: [URL] = [URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/sessions"), URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/archived_sessions")]) {
        reader = LocalUsageReader(now: now, openCodeDatabasePath: openCodeDatabasePath, hermesDatabasePath: hermesDatabasePath, codexRoots: codexRoots)
    }

    func fetch() -> UsageHistoryResult {
        let snapshot = reader.fetch()
        return UsageHistoryResult(buckets: Self.makeBuckets(events: snapshot.observations.map {
            UsageTokenEvent(provider: $0.provider, timestamp: $0.hour, inputTokens: Int64($0.tokens))
        }, now: reader.now), anySourceReadable: snapshot.anyAvailable)
    }

    static func makeBuckets(events: [UsageTokenEvent], now: Date) -> [HourlyUsageBucket] {
        let endHour = floor(now.timeIntervalSince1970 / 3_600) * 3_600
        let firstHour = endHour - Double(bucketCount - 1) * 3_600
        var openAI = Array(repeating: Int64(0), count: bucketCount)
        var deepseek = Array(repeating: Int64(0), count: bucketCount)
        for event in events where event.timestamp <= now && event.inputTokens >= 0 {
            let eventHour = floor(event.timestamp.timeIntervalSince1970 / 3_600) * 3_600
            let index = Int((eventHour - firstHour) / 3_600)
            guard (0..<bucketCount).contains(index) else { continue }
            switch event.provider {
            case .openAI: openAI[index] += event.inputTokens
            case .deepseek: deepseek[index] += event.inputTokens
            }
        }
        return (0..<bucketCount).map { index in
            let start = max(0, index - 2)
            let count = Double(index - start + 1)
            return HourlyUsageBucket(hour: Date(timeIntervalSince1970: firstHour + Double(index) * 3_600),
                openAIInputTokens: openAI[index], deepseekInputTokens: deepseek[index],
                smoothedOpenAIInputTokens: openAI[start...index].reduce(0.0) { $0 + Double($1) } / count,
                smoothedDeepseekInputTokens: deepseek[start...index].reduce(0.0) { $0 + Double($1) } / count)
        }
    }
}
