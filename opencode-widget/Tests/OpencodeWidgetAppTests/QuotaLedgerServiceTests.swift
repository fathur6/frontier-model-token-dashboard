import XCTest
@testable import OpencodeWidgetApp
@testable import OpencodeWidgetLedger
import OpencodeWidgetShared

@MainActor
final class QuotaLedgerServiceTests: XCTestCase {
    func testFiveHourOnlyRefreshPersistsAndSeedingPreservesQuotaWithoutWeeklyHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("five-hour-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = QuotaLedgerService(ledgerPath: dir.appendingPathComponent("quota.db").path, now: { now }, hourlyTotals: { nil }, deepseekHourlyTotals: { nil })
        let quota = OpenAIQuota(fiveHourRemainingPercent: 80, fiveHourResetDate: now.addingTimeInterval(18000))
        let cache = WidgetCache(openAIQuota: quota)
        service.recordRefresh(cache: cache)
        let row = try XCTUnwrap(service.ledger.recentSnapshots(limit: 1).first)
        XCTAssertEqual(row.fiveHourRemainingPercent, 80)
        XCTAssertEqual(row.fiveHourResetDate, quota.fiveHourResetDate)
        XCTAssertNil(row.openaiPercent)
        XCTAssertEqual(row.source, "openai")
        let seeded = service.seededCache(from: cache)
        XCTAssertEqual(seeded.openAIQuota, quota)
        XCTAssertTrue(seeded.openAIQuotaHistory.isEmpty)

        let both = OpenAIQuota(remainingPercent: 40, resetDate: now.addingTimeInterval(604800), fiveHourRemainingPercent: 60, fiveHourResetDate: now.addingTimeInterval(9000))
        service.recordRefresh(cache: WidgetCache(openAIQuota: both))
        XCTAssertEqual(service.seededCache(from: WidgetCache(openAIQuota: both)).openAIQuotaHistory.map(\.remainingPercent), [40])
    }
    func testOpenCreatesLedger() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("quota.db").path
        let service = QuotaLedgerService(ledgerPath: path, hourlyTotals: { nil }, deepseekHourlyTotals: { nil })
        XCTAssertNotNil(service.ledger)
        XCTAssertEqual(service.ledger.count(), 0)
    }

    func testRecordRefreshBackfillsOnceThenRecords() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs2-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("quota.db").path
        let service = QuotaLedgerService(ledgerPath: path, hourlyTotals: { nil }, deepseekHourlyTotals: { nil })

        let hour = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = WidgetCache(
            deepseek: ProviderBalance(balance: 10, currency: "USD"),
            openAIQuota: OpenAIQuota(remainingPercent: 44),
            deepseekBalanceHistory: [DeepSeekBalanceSnapshot(hour: hour, remainingRM: 45)],
            openAIQuotaHistory: [OpenAIQuotaSnapshot(hour: hour, remainingPercent: 60)]
        )
        service.recordRefresh(cache: cache)
        XCTAssertGreaterThanOrEqual(service.ledger.count(), 2)

        service.recordRefresh(cache: cache)
        XCTAssertGreaterThanOrEqual(service.ledger.count(), 1)
    }

    func testRecordRefreshPreservesCurrentHourOpenAIUsageWhenCollectionIsUnavailable() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs3-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("quota.db").path
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let service = QuotaLedgerService(ledgerPath: path, now: { now }, hourlyTotals: { nil }, deepseekHourlyTotals: { nil })
        service.ledger.record(
            hour: now,
            deepseekUSD: nil,
            openaiPercent: nil,
            openAIInputTokens: 123,
            openAIEstimatedCostUSD: 4.56,
            source: "openai"
        )

        service.recordRefresh(cache: WidgetCache(deepseek: ProviderBalance(balance: 10, currency: "USD")))

        let row = service.ledger.recentSnapshots(limit: 1).first
        XCTAssertEqual(row?.openAIInputTokens, 123)
        XCTAssertEqual(row?.openAIEstimatedCostUSD, 4.56)
    }

    func testCostWindowStartsOneHundredSixtyEightHoursBeforeReset() {
        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(
            QuotaLedgerService.costWindowStart(resetDate: reset),
            reset.addingTimeInterval(-168 * 3_600)
        )
    }

    func testRecordRefreshPersistsDeepSeekUsageIntoSeededUsageChart() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs4-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("quota.db").path
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let currentHour = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3_600) * 3_600)
        let service = QuotaLedgerService(
            ledgerPath: path,
            now: { now },
            hourlyTotals: { [currentHour: OpenAIHourlyTotal(inputTokens: 55, estimatedCostUSD: 0.75)] },
            deepseekHourlyTotals: { [currentHour: DeepSeekHourlyTotal(inputTokens: 777)] }
        )

        service.recordRefresh(cache: WidgetCache(deepseek: ProviderBalance(balance: 10, currency: "USD")))

        let row = service.ledger.recentSnapshots(limit: 1).first
        XCTAssertEqual(row?.deepseekInputTokens, 777)
        XCTAssertEqual(row?.openAIInputTokens, 55)

        let usageBuckets = service.seededCache(from: WidgetCache()).hourlyUsage
        XCTAssertEqual(usageBuckets.last?.deepseekInputTokens, 777)

        let firstHour = usageBuckets.first?.hour ?? now
        let lastHour = usageBuckets.last?.hour ?? now
        let projection = UsageHistoryChartProjection(buckets: usageBuckets, xDomain: firstHour...lastHour)
        let deepseekSeries = projection.series.first { $0.provider == .deepseek }
        XCTAssertNotNil(deepseekSeries)
        XCTAssertTrue(deepseekSeries?.points.contains { $0.tokens > 0 } ?? false)
    }

    func testRecordRefreshPreservesDeepSeekUsageWhenCollectionUnavailable() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qs5-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("quota.db").path
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let service = QuotaLedgerService(ledgerPath: path, now: { now }, hourlyTotals: { nil }, deepseekHourlyTotals: { nil })
        service.ledger.record(
            hour: now,
            deepseekUSD: nil,
            openaiPercent: nil,
            deepseekInputTokens: 321,
            source: "usage"
        )

        service.recordRefresh(cache: WidgetCache(deepseek: ProviderBalance(balance: 10, currency: "USD")))

        XCTAssertEqual(service.ledger.recentSnapshots(limit: 1).first?.deepseekInputTokens, 321)
    }

    func testUnifiedMultiClientRecoveryProjectsNonzeroPriorHoursAndSurvivesRepeatedPartialRefresh() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DAF-26-service-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_800_000_123)
        let current = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3_600) * 3_600)
        let old = current.addingTimeInterval(-3_600)
        let openCode = LocalUsageObservation(source:.openCode,id:"v2-message",provider:.openAI,sessionID:"opencode",hour:old,tokens:100)
        let codex = LocalUsageObservation(source:.codex,id:"codex-event",provider:.deepseek,sessionID:"codex",hour:old,tokens:50)
        let hermes = LocalUsageObservation(source:.hermes,id:"cumulative-row",provider:.openAI,sessionID:"independent-hermes",hour:old,tokens:20)
        let good = LocalUsageSnapshot(from:current.addingTimeInterval(-719*3_600),through:now,batches:[
            LocalUsageBatch(source:.openCode,availability:.available,observations:[openCode]),
            LocalUsageBatch(source:.codex,availability:.available,observations:[codex]),
            LocalUsageBatch(source:.hermes,availability:.available,observations:[hermes])])
        let service = QuotaLedgerService(ledgerPath:dir.appendingPathComponent("quota.db").path,now:{now},localUsage:{good})
        let cache = WidgetCache(deepseek:ProviderBalance(balance:10),openAIQuota:OpenAIQuota(remainingPercent:44,resetDate:old.addingTimeInterval(604_800)))
        for _ in 0..<3 { service.recordRefresh(cache:cache) }
        let seeded = service.seededCache(from:cache)
        XCTAssertEqual(seeded.hourlyUsage.reduce(0){$0+$1.openAIInputTokens},120)
        XCTAssertEqual(seeded.hourlyUsage.reduce(0){$0+$1.deepseekInputTokens},50)
        XCTAssertEqual(seeded.deepseekBalanceHistory.last?.remainingRM,45)
        XCTAssertEqual(seeded.openAIQuotaHistory.last?.remainingPercent,44)
        XCTAssertNil(service.activeOpenAIEstimatedCost(resetDate:cache.openAIQuota?.resetDate,now:now))
        XCTAssertNil(seeded.usageHistoryWarning)
        let projection = UsageHistoryChartProjection(buckets:seeded.hourlyUsage,xDomain:ChartWindow.range(endingAt:current,offsetHours:0))
        XCTAssertTrue(projection.series.allSatisfy { $0.points.contains { $0.plotTokens > 0 } })

        let partial = LocalUsageSnapshot(from:good.from,through:now,batches:[
            LocalUsageBatch(source:.openCode,availability:.failed),
            LocalUsageBatch(source:.codex,availability:.available,observations:[codex]),
            LocalUsageBatch(source:.hermes,availability:.missing)])
        service.recordRefresh(cache:cache,usage:partial)
        let retained = service.seededCache(from:cache)
        XCTAssertEqual(retained.hourlyUsage,seeded.hourlyUsage)
        XCTAssertNotNil(retained.usageHistoryWarning)
        let roundtrip = try JSONDecoder().decode(WidgetCache.self,from:JSONEncoder().encode(retained))
        XCTAssertEqual(roundtrip.usageHistoryWarning,retained.usageHistoryWarning)
    }

    func testUsageOnlyRefreshStillPrunesExpiredProvenanceAndHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DAF-26-retention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var clock = Date(timeIntervalSince1970:1_800_000_123)
        let old = clock
        let observation = LocalUsageObservation(source:.codex,id:"old",provider:.openAI,hour:old,tokens:100)
        let initial = LocalUsageSnapshot(from:old.addingTimeInterval(-3_600),through:old,
            batches:[LocalUsageBatch(source:.codex,availability:.available,observations:[observation])])
        let service = QuotaLedgerService(ledgerPath:dir.appendingPathComponent("quota.db").path,now:{clock},localUsage:{initial})
        service.recordRefresh(cache:WidgetCache())
        XCTAssertEqual(service.ledger.count(),1)
        clock = Calendar.current.date(byAdding:.month,value:13,to:old)!
        service.recordRefresh(cache:WidgetCache(),usage:LocalUsageSnapshot(from:clock.addingTimeInterval(-30*24*3_600),through:clock,
            batches:[LocalUsageBatch(source:.codex,availability:.available)]))
        XCTAssertEqual(service.ledger.count(),0)
    }
}
