import Foundation
import SQLite3
#if canImport(OpencodeWidgetShared)
import OpencodeWidgetShared
#endif

struct DeepSeekHourlyTotal: Sendable, Equatable { let inputTokens: Int }

struct DeepSeekUsageSample: Sendable {
    let hour: Date
    let inputTokens: Int64

    init(hour: Date, inputTokens: Int64) {
        self.hour = Date(timeIntervalSince1970: floor(hour.timeIntervalSince1970 / 3_600) * 3_600)
        self.inputTokens = inputTokens
    }
}

struct DeepSeekUsageCollector: Sendable {
    private var reader: LocalUsageReader

    init(now: Date = Date(),
         openCodeDatabasePath: String = "\(NSHomeDirectory())/.local/share/opencode/opencode.db",
         hermesDatabasePath: String = "\(NSHomeDirectory())/.hermes/state.db",
         codexRoots: [URL] = [URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/sessions"), URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/archived_sessions")],
         databaseStep: @escaping @Sendable (OpaquePointer?) -> Int32 = sqlite3_step) {
        reader = LocalUsageReader(now: now, openCodeDatabasePath: openCodeDatabasePath, hermesDatabasePath: hermesDatabasePath, codexRoots: codexRoots)
        reader.databaseStep = databaseStep
    }

    func hourlyTotals() -> [Date: DeepSeekHourlyTotal]? {
        let snapshot = reader.fetch()
        guard snapshot.anyAvailable, !snapshot.hasFailures else { return nil }
        let samples = snapshot.observations.filter { $0.provider == .deepseek }.map {
            DeepSeekUsageSample(hour: $0.hour, inputTokens: Int64($0.tokens))
        }
        return Self.aggregate(samples)
    }

    static func aggregate(_ samples: [DeepSeekUsageSample]) -> [Date: DeepSeekHourlyTotal] {
        var totals: [Date: DeepSeekHourlyTotal] = [:]
        for sample in samples {
            totals[sample.hour] = DeepSeekHourlyTotal(inputTokens: (totals[sample.hour]?.inputTokens ?? 0) + Int(max(0, sample.inputTokens)))
        }
        return totals
    }
}
