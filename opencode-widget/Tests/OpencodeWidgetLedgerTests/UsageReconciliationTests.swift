import XCTest
@testable import OpencodeWidgetLedger
import OpencodeWidgetShared

final class UsageReconciliationTests: XCTestCase {
    private var root: URL!
    private var ledger: QuotaLedger!
    private let hour = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DAF-26-ledger-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ledger = QuotaLedger(path: root.appendingPathComponent("quota.db").path)
    }
    override func tearDownWithError() throws { ledger = nil; try FileManager.default.removeItem(at: root) }

    private func observation(_ source: LocalUsageSource, _ id: String, tokens: Int, hoursAgo: Int = 0,
                             provider: LocalUsageProvider = .openAI, session: String = "", request: String = "", cost: Double? = nil) -> LocalUsageObservation {
        LocalUsageObservation(source: source, id: id, provider: provider, sessionID: session, requestID: request,
            hour: hour.addingTimeInterval(Double(-hoursAgo) * 3_600), tokens: tokens, estimatedCostUSD: cost)
    }
    private func batch(_ source: LocalUsageSource, _ observations: [LocalUsageObservation] = [],
                       status: LocalUsageAvailability = .available) -> LocalUsageBatch {
        LocalUsageBatch(source: source, availability: status, observations: observations)
    }
    private func reconcile(_ batches: [LocalUsageBatch]) -> Bool {
        ledger.reconcileUsage(LocalUsageSnapshot(from: hour.addingTimeInterval(-719 * 3_600), through: hour.addingTimeInterval(60), batches: batches))
    }

    func testHistoricalRecoveryIsIdempotentAndPreservesQuotaBalanceFields() throws {
        let previous = hour.addingTimeInterval(-3_600)
        ledger.record(hour: previous, deepseekUSD: 12, openaiPercent: 44, fiveHourRemainingPercent: 80,
            fiveHourResetDate: hour.addingTimeInterval(18_000), source: "both")
        let observations = [observation(.openCode, "a", tokens: 100, hoursAgo: 1), observation(.codex, "b", tokens: 50, hoursAgo: 2)]
        for _ in 0..<3 {
            XCTAssertTrue(reconcile([batch(.openCode, [observations[0]]), batch(.codex, [observations[1]]), batch(.hermes, status: .missing)]))
        }
        let rows = ledger.recentSnapshots(limit: 10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap(\.openAIInputTokens).reduce(0,+), 150)
        let quota = try XCTUnwrap(rows.last)
        XCTAssertEqual(quota.deepseekUSD, 12)
        XCTAssertEqual(quota.openaiPercent, 44)
        XCTAssertEqual(quota.fiveHourRemainingPercent, 80)
        XCTAssertEqual(quota.fiveHourResetDate, hour.addingTimeInterval(18_000))
        XCTAssertNil(quota.openAIEstimatedCostUSD)
        XCTAssertNil(ledger.activeOpenAIEstimatedCost(from: previous, through: hour))
    }

    func testFailedOrMissingSourceRetainsContributionsWhileHealthySourceUpdatesAndAfterReopen() throws {
        XCTAssertTrue(reconcile([batch(.openCode, [observation(.openCode,"a",tokens:100)]), batch(.codex,[observation(.codex,"b",tokens:50)])]))
        XCTAssertTrue(reconcile([batch(.openCode, [observation(.openCode,"a",tokens:120)]), batch(.codex,status:.failed)]))
        XCTAssertEqual(ledger.recentSnapshots(limit: 1).first?.openAIInputTokens, 170)
        XCTAssertTrue(reconcile([batch(.openCode, [observation(.openCode,"a",tokens:130)]), batch(.codex,status:.missing)]))
        XCTAssertEqual(ledger.recentSnapshots(limit: 1).first?.openAIInputTokens, 180)
        ledger = nil
        ledger = QuotaLedger(path: root.appendingPathComponent("quota.db").path)
        XCTAssertTrue(reconcile([batch(.openCode, [observation(.openCode,"a",tokens:140)]), batch(.codex,status:.failed)]))
        XCTAssertEqual(ledger.recentSnapshots(limit: 1).first?.openAIInputTokens, 190)
    }

    func testHermesCumulativeObservationMovesHourRatherThanBeingCountedAgain() throws {
        XCTAssertTrue(reconcile([batch(.hermes,[observation(.hermes,"stable-row",tokens:100,hoursAgo:1)])]))
        XCTAssertTrue(reconcile([batch(.hermes,[observation(.hermes,"stable-row",tokens:150)])]))
        for _ in 0..<3 { XCTAssertTrue(reconcile([batch(.hermes,[observation(.hermes,"stable-row",tokens:150)])])) }
        let rows = ledger.recentSnapshots(limit: 10)
        XCTAssertEqual(rows.map(\.openAIInputTokens), [0, 150])
        XCTAssertEqual(rows.compactMap(\.openAIInputTokens).reduce(0,+), 150)
    }

    func testRequestAndMirroredSessionDeduplicationPersistsAcrossPartialRefresh() throws {
        let direct = observation(.openCode,"a",tokens:100,session:"shared",request:"request")
        let codexMirror = observation(.codex,"b",tokens:100,session:"different",request:"request")
        let hermesMirror = observation(.hermes,"c",tokens:100,session:"shared")
        let independent = observation(.hermes,"d",tokens:50,session:"other")
        XCTAssertTrue(reconcile([batch(.openCode,[direct]),batch(.codex,[codexMirror]),batch(.hermes,[hermesMirror,independent])]))
        XCTAssertEqual(ledger.recentSnapshots(limit: 1).first?.openAIInputTokens, 150)
        XCTAssertTrue(reconcile([batch(.openCode,status:.failed),batch(.codex,[codexMirror]),batch(.hermes,[hermesMirror,independent])]))
        XCTAssertEqual(ledger.recentSnapshots(limit: 1).first?.openAIInputTokens, 150)
    }

    func testLegacyCompleteTotalsAreNotReducedOrAdoptedFromPartialRead() throws {
        ledger.record(hour:hour,deepseekUSD:5,openaiPercent:50,openAIInputTokens:1_000,openAIEstimatedCostUSD:1,source:"legacy")
        for _ in 0..<2 {
            XCTAssertTrue(reconcile([batch(.openCode,[observation(.openCode,"a",tokens:100)]),batch(.codex,status:.failed)]))
            XCTAssertEqual(ledger.recentSnapshots(limit:1).first?.openAIInputTokens,1_000)
        }
        XCTAssertTrue(reconcile([batch(.openCode,[observation(.openCode,"a",tokens:100)]),batch(.codex,status:.missing)]))
        XCTAssertEqual(ledger.recentSnapshots(limit:1).first?.openAIInputTokens,1_000)
        XCTAssertTrue(reconcile([batch(.openCode,[observation(.openCode,"a",tokens:1_100)]),batch(.codex,status:.available)]))
        XCTAssertEqual(ledger.recentSnapshots(limit:1).first?.openAIInputTokens,1_100)
        XCTAssertNil(ledger.recentSnapshots(limit:1).first?.openAIEstimatedCostUSD)
    }

    func testUnknownPriceClearsStaleEstimateWithoutDiscardingUsage() throws {
        XCTAssertTrue(reconcile([batch(.openCode,[observation(.openCode,"a",tokens:100,cost:1)])]))
        XCTAssertEqual(ledger.activeOpenAIEstimatedCost(from:hour,through:hour),1)
        XCTAssertTrue(reconcile([batch(.openCode,[observation(.openCode,"a",tokens:150)])]))
        XCTAssertEqual(ledger.recentSnapshots(limit:1).first?.openAIInputTokens,150)
        XCTAssertNil(ledger.recentSnapshots(limit:1).first?.openAIEstimatedCostUSD)
        XCTAssertNil(ledger.activeOpenAIEstimatedCost(from:hour,through:hour))
    }

    func testInvalidBatchRollsBackProvenanceAndProjectionTogether() throws {
        XCTAssertTrue(reconcile([batch(.openCode,[observation(.openCode,"a",tokens:100)])]))
        XCTAssertFalse(reconcile([batch(.openCode,[observation(.codex,"bad-source",tokens:999)])]))
        XCTAssertEqual(ledger.recentSnapshots(limit:1).first?.openAIInputTokens,100)
        XCTAssertTrue(reconcile([batch(.openCode,status:.missing),batch(.hermes,[])]))
        XCTAssertEqual(ledger.recentSnapshots(limit:1).first?.openAIInputTokens,100)
    }

    func testHealthyEmptySourceCanRemoveManagedContribution() throws {
        XCTAssertTrue(reconcile([batch(.openCode,[observation(.openCode,"a",tokens:100)])]))
        XCTAssertTrue(reconcile([batch(.openCode,[])]))
        XCTAssertEqual(ledger.recentSnapshots(limit:1).first?.openAIInputTokens,0)
    }

    func testSlowOlderRefreshCannotReplaceNewerSourceContributions() throws {
        XCTAssertTrue(reconcile([batch(.openCode,[observation(.openCode,"a",tokens:100)])]))
        let older = LocalUsageSnapshot(from: hour.addingTimeInterval(-719 * 3_600), through: hour,
            batches: [batch(.openCode,[observation(.openCode,"a",tokens:10)])])
        XCTAssertTrue(ledger.reconcileUsage(older))
        XCTAssertEqual(ledger.recentSnapshots(limit:1).first?.openAIInputTokens,100)
    }

    func testRetentionPrunesProvenanceSoLaterRefreshCannotResurrectDeletedHours() throws {
        let old = Calendar.current.date(byAdding:.month,value:-13,to:hour)!
        let observation = LocalUsageObservation(source:.hermes,id:"old",provider:.openAI,hour:old,tokens:100)
        XCTAssertTrue(ledger.reconcileUsage(LocalUsageSnapshot(from:old.addingTimeInterval(-3_600),through:hour,
            batches:[batch(.hermes,[observation])])))
        ledger.prune(retentionMonths:12,now:hour)
        XCTAssertEqual(ledger.count(),0)
        XCTAssertTrue(reconcile([batch(.hermes,status:.missing),batch(.codex,[])]))
        XCTAssertEqual(ledger.count(),0)
    }
}
