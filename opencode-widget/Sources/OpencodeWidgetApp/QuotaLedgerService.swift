import Foundation
#if canImport(OpencodeWidgetLedger)
import OpencodeWidgetLedger
#endif
#if canImport(OpencodeWidgetShared)
import OpencodeWidgetShared
#endif

struct ProcessQuotaEmailSender: QuotaEmailSending {
    let script = "\(NSHomeDirectory())/.hermes/skills/productivity/google-workspace/scripts/google_api.py"

    func sendQuotaReport(subject: String, body: String, to: String) async -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script, "gmail", "send", "--to", to, "--subject", subject, "--body", body]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }
}

@MainActor
final class QuotaLedgerService {
    static let shared = QuotaLedgerService()

    let ledger: QuotaLedger
    private let reporter: QuotaMonthlyReporter
    private let to = "fathur6@gmail.com"
    private let now: () -> Date
    private let hourlyTotals: () -> [Date: OpenAIHourlyTotal]?
    private let deepseekHourlyTotals: () -> [Date: DeepSeekHourlyTotal]?
    private let localUsage: (() -> LocalUsageSnapshot)?
    private var usageHistoryWarning: String?

    init(
        ledgerPath: String? = nil,
        now: @escaping () -> Date = Date.init,
        hourlyTotals: (() -> [Date: OpenAIHourlyTotal]?)? = nil,
        deepseekHourlyTotals: (() -> [Date: DeepSeekHourlyTotal]?)? = nil,
        localUsage: (() -> LocalUsageSnapshot)? = nil
    ) {
        let fm = FileManager.default
        let base = ledgerPath ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpencodeWidgetApp", isDirectory: true).path
        let dbPath = ledgerPath ?? "\(base)/quota.db"
        let parent = (dbPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let ledger = QuotaLedger.open(path: dbPath)
        let sender = ProcessQuotaEmailSender()
        let archiveDir = "\(base)/archive"
        self.ledger = ledger
        self.reporter = QuotaMonthlyReporter(ledger: ledger, sender: sender, to: to, now: { Date() }, archiveDir: archiveDir)
        self.now = now
        self.hourlyTotals = hourlyTotals ?? { nil }
        self.deepseekHourlyTotals = deepseekHourlyTotals ?? { nil }
        self.localUsage = localUsage ?? (hourlyTotals == nil && deepseekHourlyTotals == nil ? { LocalUsageReader(now: now()).fetch() } : nil)
    }

    func begin(of cache: WidgetCache) {
        ledger.backfill(deepseek: cache.deepseekBalanceHistory, openAI: cache.openAIQuotaHistory)
        ledger.prune(retentionMonths: 12)
    }

    /// Merge the durable ledger's recent snapshots into the cache's in-memory
    /// history so the visible Quota chart reflects persisted data across rebuilds.
    func seededCache(from cache: WidgetCache, limit: Int = 720) -> WidgetCache {
        let rows = ledger.recentSnapshots(limit: limit)
        guard !rows.isEmpty else {
            var result = cache
            result.usageHistoryWarning = usageHistoryWarning
            return result
        }
        let deepseekHistory = rows.compactMap { row -> DeepSeekBalanceSnapshot? in
            guard let usd = row.deepseekUSD else { return nil }
            return DeepSeekBalanceSnapshot(hour: row.hour, remainingRM: usd * DeepSeekBalanceHistory.usdToMYR)
        }
        let openAIHistory = rows.compactMap { row -> OpenAIQuotaSnapshot? in
            guard let percent = row.openaiPercent else { return nil }
            return OpenAIQuotaSnapshot(hour: row.hour, remainingPercent: percent)
        }
        let hourlyUsage = Self.bucketize(rows: rows, limit: limit, now: now())
        return WidgetCache(
            lastUpdated: cache.lastUpdated,
            deepseek: cache.deepseek,
            minimax: cache.minimax,
            minimaxUsage: cache.minimaxUsage,
            minimaxCredit: cache.minimaxCredit,
            minimaxCreditFetched: cache.minimaxCreditFetched,
            dailyUsage: cache.dailyUsage,
            openAIQuota: cache.openAIQuota,
            hourlyUsage: hourlyUsage,
            deepseekBalanceHistory: deepseekHistory,
            openAIQuotaHistory: openAIHistory,
            usageHistoryWarning: usageHistoryWarning
        )
    }

    func recordRefresh(cache: WidgetCache, usage: LocalUsageSnapshot? = nil) {
        if ledger.count() == 0 { begin(of: cache) }
        let now = now()
        defer { ledger.prune(retentionMonths: 12, now: now) }
        let dsUSD = cache.deepseek.balance
        let oaPercent = cache.openAIQuota?.remainingPercent
        let fiveHourPercent = cache.openAIQuota?.fiveHourRemainingPercent
        if let snapshot = usage ?? localUsage?() {
            let saved = !snapshot.anyAvailable || ledger.reconcileUsage(snapshot)
            if !saved { usageHistoryWarning = "Usage history could not be saved; prior history retained." }
            else if snapshot.hasFailures {
                let names = snapshot.batches.filter { $0.availability == .failed }.map { $0.source.rawValue }.joined(separator: ", ")
                usageHistoryWarning = "Usage history incomplete (\(names)); prior observations retained."
            } else if !snapshot.anyAvailable { usageHistoryWarning = "Local usage history unavailable." }
            else { usageHistoryWarning = nil }
        } else {
            // Injectable compatibility path: replace every observed hour, never
            // add cumulative totals on each refresh or ignore historical hours.
            let openAI = hourlyTotals()
            let deepseek = deepseekHourlyTotals()
            for hour in Set(openAI?.keys.map { $0 } ?? []).union(deepseek?.keys.map { $0 } ?? []) {
                ledger.record(hour: hour, deepseekUSD: nil, openaiPercent: nil,
                    deepseekInputTokens: deepseek?[hour]?.inputTokens,
                    openAIInputTokens: openAI?[hour]?.inputTokens,
                    openAIEstimatedCostUSD: openAI?[hour]?.estimatedCostUSD, source: "usage")
            }
        }
        guard dsUSD != nil || oaPercent != nil || fiveHourPercent != nil else { return }
        ledger.record(
            hour: now,
            deepseekUSD: dsUSD,
            openaiPercent: oaPercent,
            fiveHourRemainingPercent: fiveHourPercent,
            fiveHourResetDate: cache.openAIQuota?.fiveHourResetDate,
            source: sourceLabel(ds: dsUSD, oa: oaPercent ?? fiveHourPercent)
        )
    }

    func runMonthlyReportIfDue() async {
        _ = await reporter.runIfDue()
    }

    static func costWindowStart(resetDate: Date) -> Date {
        resetDate.addingTimeInterval(-168 * 3_600)
    }

    func activeOpenAIEstimatedCost(resetDate: Date?, now: Date = Date()) -> Double? {
        guard let resetDate else { return nil }
        return ledger.activeOpenAIEstimatedCost(from: Self.costWindowStart(resetDate: resetDate), through: now)
    }

    private func sourceLabel(ds: Double?, oa: Double?) -> String {
        switch (ds, oa) {
        case (.some, .some): return "both"
        case (.some, nil): return "deepseek"
        case (nil, .some): return "openai"
        case (nil, nil): return "usage"
        }
    }

    /// Builds the Usage chart's contiguous hourly buckets from ledger rows,
    /// reproducing the trailing-mean smoothing the prior fetcher path produced.
    /// Missing hours are filled with zero-token buckets so the chart remains a
    /// fixed window ending at the newest recorded hour.
    private static func bucketize(rows: [QuotaSnapshotRow], limit: Int, now: Date) -> [HourlyUsageBucket] {
        guard let newest = rows.last?.hour else { return [] }
        let endHour = Date(timeIntervalSince1970: floor(max(newest, now).timeIntervalSince1970 / 3_600) * 3_600)
        let bucketCount = max(1, limit)
        let firstHour = endHour.addingTimeInterval(-Double(bucketCount - 1) * 3_600)
        var openAI = Array(repeating: Int64(0), count: bucketCount)
        var deepseek = Array(repeating: Int64(0), count: bucketCount)
        for row in rows {
            let hour = Date(timeIntervalSince1970: floor(row.hour.timeIntervalSince1970 / 3_600) * 3_600)
            let index = Int((hour.timeIntervalSince1970 - firstHour.timeIntervalSince1970) / 3_600)
            guard (0..<bucketCount).contains(index) else { continue }
            openAI[index] = Int64(row.openAIInputTokens ?? 0)
            deepseek[index] = Int64(row.deepseekInputTokens ?? 0)
        }
        return (0..<bucketCount).map { index in
            let start = max(0, index - 2)
            let count = Double(index - start + 1)
            let smoothedOpenAI = openAI[start...index].reduce(0.0) { $0 + Double($1) } / count
            let smoothedDeepseek = deepseek[start...index].reduce(0.0) { $0 + Double($1) } / count
            return HourlyUsageBucket(
                hour: Date(timeIntervalSince1970: firstHour.timeIntervalSince1970 + Double(index) * 3_600),
                openAIInputTokens: openAI[index],
                deepseekInputTokens: deepseek[index],
                smoothedOpenAIInputTokens: smoothedOpenAI,
                smoothedDeepseekInputTokens: smoothedDeepseek
            )
        }
    }
}
