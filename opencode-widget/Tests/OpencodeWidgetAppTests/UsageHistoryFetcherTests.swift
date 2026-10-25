import XCTest
import SQLite3
@testable import OpencodeWidgetApp
@testable import OpencodeWidgetShared

final class UsageHistoryFetcherTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_123)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testBucketingReturnsThirtyDaysOfAlignedHoursAndTrailingMean() {
        let endHour = floor(now.timeIntervalSince1970 / 3_600) * 3_600
        let firstHour = endHour - 719 * 3_600
        let events = [
            UsageTokenEvent(provider: .openAI, timestamp: Date(timeIntervalSince1970: firstHour), inputTokens: 3),
            UsageTokenEvent(provider: .openAI, timestamp: Date(timeIntervalSince1970: firstHour + 2 * 3_600), inputTokens: 9),
            UsageTokenEvent(provider: .deepseek, timestamp: Date(timeIntervalSince1970: endHour), inputTokens: 12),
            UsageTokenEvent(provider: .deepseek, timestamp: Date(timeIntervalSince1970: firstHour - 1), inputTokens: 999)
        ]

        let buckets = UsageHistoryFetcher.makeBuckets(events: events, now: now)

        XCTAssertEqual(buckets.count, 720)
        XCTAssertEqual(buckets.first?.hour, Date(timeIntervalSince1970: firstHour))
        XCTAssertEqual(buckets.last?.hour, Date(timeIntervalSince1970: endHour))
        XCTAssertEqual(buckets[0].smoothedOpenAIInputTokens, 3)
        XCTAssertEqual(buckets[1].smoothedOpenAIInputTokens, 1.5)
        XCTAssertEqual(buckets[2].smoothedOpenAIInputTokens, 4)
        XCTAssertEqual(buckets.last?.deepseekInputTokens, 12)
        XCTAssertEqual(buckets.last?.smoothedDeepseekInputTokens, 4)
    }

    func testOpenCodeExtractionIsReadOnlyAndFiltersRecords() throws {
        let db = root.appendingPathComponent("opencode.db")
        try makeDatabase(at: db, statements: [
            "CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)",
            openCodeInsert(role: "assistant", provider: "openai", milliseconds: milliseconds(hoursAgo: 1), input: 10, read: 2, write: 3),
            openCodeInsert(role: "assistant", provider: "deepseek", milliseconds: milliseconds(hoursAgo: 2), input: 20, read: 4, write: 1),
            openCodeInsert(role: "user", provider: "openai", milliseconds: milliseconds(hoursAgo: 1), input: 999, read: 0, write: 0),
            openCodeInsert(role: "assistant", provider: "minimax", milliseconds: milliseconds(hoursAgo: 1), input: 999, read: 0, write: 0),
            "PRAGMA query_only = ON"
        ])

        let result = UsageHistoryFetcher(
            now: now,
            openCodeDatabasePath: db.path,
            hermesDatabasePath: root.appendingPathComponent("missing-hermes.db").path,
            codexRoots: []
        ).fetch()

        XCTAssertTrue(result.anySourceReadable)
        XCTAssertEqual(result.buckets.reduce(0) { $0 + $1.openAIInputTokens }, 10)
        XCTAssertEqual(result.buckets.reduce(0) { $0 + $1.deepseekInputTokens }, 25)
    }

    func testHermesExtractionMapsProvidersAtLastSeen() throws {
        let db = root.appendingPathComponent("hermes.db")
        try makeDatabase(at: db, statements: [
            "CREATE TABLE session_model_usage (model TEXT, billing_provider TEXT, input_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, last_seen INTEGER)",
            "INSERT INTO session_model_usage VALUES ('gpt-6.1-sol', 'openai-codex', 8, 2, 1, \(seconds(hoursAgo: 1)))",
            "INSERT INTO session_model_usage VALUES ('deepseek-flash', 'deepseek', 20, 3, 2, \(seconds(hoursAgo: 2)))",
            "INSERT INTO session_model_usage VALUES ('other', 'other', 999, 0, 0, \(seconds(hoursAgo: 1)))"
        ])

        let result = UsageHistoryFetcher(
            now: now,
            openCodeDatabasePath: root.appendingPathComponent("missing-open.db").path,
            hermesDatabasePath: db.path,
            codexRoots: []
        ).fetch()

        XCTAssertTrue(result.anySourceReadable)
        XCTAssertEqual(result.buckets.reduce(0) { $0 + $1.openAIInputTokens }, 8)
        XCTAssertEqual(result.buckets.reduce(0) { $0 + $1.deepseekInputTokens }, 25)
    }

    func testMissingSourcesAreUnavailableButPresentEmptyCodexIsReadable() throws {
        let missing = root.appendingPathComponent("missing")
        let unavailable = UsageHistoryFetcher(
            now: now,
            openCodeDatabasePath: missing.path,
            hermesDatabasePath: missing.path,
            codexRoots: [missing]
        ).fetch()
        XCTAssertFalse(unavailable.anySourceReadable)

        let emptyRoot = root.appendingPathComponent("empty-codex")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let readable = UsageHistoryFetcher(
            now: now,
            openCodeDatabasePath: missing.path,
            hermesDatabasePath: missing.path,
            codexRoots: [emptyRoot]
        ).fetch()
        XCTAssertTrue(readable.anySourceReadable)
        XCTAssertEqual(readable.buckets.count, 720)
        XCTAssertTrue(readable.buckets.allSatisfy { $0.openAIInputTokens == 0 && $0.deepseekInputTokens == 0 })
    }

    func testChartProjectionHasExactlyTwoColoredSeriesAndFiniteDomain() {
        let buckets = [
            HourlyUsageBucket(hour: now, smoothedOpenAIInputTokens: 10, smoothedDeepseekInputTokens: 5),
            HourlyUsageBucket(hour: now.addingTimeInterval(3_600))
        ]
        let xDomain = now...now.addingTimeInterval(167 * 3_600)

        let projection = UsageHistoryChartProjection(buckets: buckets, xDomain: xDomain)

        XCTAssertEqual(projection.series.map(\.provider), [.openAI, .deepseek])
        XCTAssertEqual(projection.series.map(\.colorName), ["green", "blue"])
        XCTAssertEqual(projection.series.map(\.points.count), [2, 2])
        XCTAssertEqual(projection.yDomain.lowerBound, 0)
        XCTAssertTrue(projection.yDomain.upperBound.isFinite)
        XCTAssertGreaterThan(projection.yDomain.upperBound, 0)
        XCTAssertEqual(projection.xDomain, xDomain)
    }

    func testOpenAIUsesHiddenAutoMaxOnY2WhileDeepSeekKeepsVisibleScale() {
        // DeepSeek dwarfs OpenAI on the shared axis; the hidden y2 auto-max must
        // lift the OpenAI peak to the top of the plot without changing its shape.
        let deepseek = [1_000.0, 500, 0, 250]
        let openAI = [10.0, 4, 0, 2]
        let buckets = zip(deepseek, openAI).enumerated().map { index, pair in
            HourlyUsageBucket(
                hour: now.addingTimeInterval(Double(index) * 3_600),
                smoothedOpenAIInputTokens: pair.1,
                smoothedDeepseekInputTokens: pair.0
            )
        }
        let xDomain = now...now.addingTimeInterval(167 * 3_600)

        let projection = UsageHistoryChartProjection(buckets: buckets, xDomain: xDomain)

        XCTAssertEqual(projection.deepseekMaxTokens, 1_000)
        XCTAssertEqual(projection.openAIMaxTokens, 10)
        XCTAssertEqual(projection.yDomain.upperBound, 1_100, accuracy: 0.0001)

        let openAISeries = projection.series.first { $0.provider == .openAI }!
        let deepseekSeries = projection.series.first { $0.provider == .deepseek }!
        // Real token counts are preserved for accessibility.
        XCTAssertEqual(openAISeries.points.map(\.tokens), openAI)
        // OpenAI's own max lands at the top of the visible DeepSeek domain...
        XCTAssertEqual(openAISeries.points[0].plotTokens, 1_000, accuracy: 0.0001)
        // ...and its shape stays proportional to its own auto-max.
        XCTAssertEqual(openAISeries.points[1].plotTokens, 400, accuracy: 0.0001)
        XCTAssertEqual(openAISeries.points[3].plotTokens, 200, accuracy: 0.0001)
        // DeepSeek still plots on its own real scale.
        XCTAssertEqual(deepseekSeries.points.map(\.plotTokens), deepseek)
    }

    func testProjectionHandlesAllZeroAndNonFiniteValuesWithoutNaN() {
        let buckets = [
            HourlyUsageBucket(hour: now, smoothedOpenAIInputTokens: .nan, smoothedDeepseekInputTokens: .infinity),
            HourlyUsageBucket(hour: now.addingTimeInterval(3_600))
        ]
        let xDomain = now...now.addingTimeInterval(167 * 3_600)

        let projection = UsageHistoryChartProjection(buckets: buckets, xDomain: xDomain)

        XCTAssertTrue(projection.yDomain.upperBound.isFinite)
        XCTAssertGreaterThan(projection.yDomain.upperBound, 0)
        XCTAssertEqual(projection.deepseekMaxTokens, 1)
        XCTAssertEqual(projection.openAIMaxTokens, 1)
        for point in projection.series.flatMap(\.points) {
            XCTAssertTrue(point.tokens.isFinite)
            XCTAssertTrue(point.plotTokens.isFinite)
            XCTAssertGreaterThanOrEqual(point.plotTokens, 0)
            XCTAssertLessThanOrEqual(point.plotTokens, projection.yDomain.upperBound)
        }
    }

    private func milliseconds(hoursAgo: Int) -> Int64 { Int64(now.addingTimeInterval(Double(-hoursAgo * 3_600)).timeIntervalSince1970 * 1_000) }
    private func seconds(hoursAgo: Int) -> Int64 { Int64(now.addingTimeInterval(Double(-hoursAgo * 3_600)).timeIntervalSince1970) }

    private func openCodeInsert(role: String, provider: String, milliseconds: Int64, input: Int, read: Int, write: Int) -> String {
        let json = #"{"role":"\#(role)","providerID":"\#(provider)","tokens":{"input":\#(input),"cache":{"read":\#(read),"write":\#(write)}}}"#
        return "INSERT INTO message VALUES ('\(UUID().uuidString)', 's', \(milliseconds), \(milliseconds), '\(json)')"
    }

    private func makeDatabase(at url: URL, statements: [String]) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        for statement in statements {
            var error: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, statement, nil, nil, &error)
            if result != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(error)
                XCTFail(message)
                throw NSError(domain: "SQLite", code: Int(result))
            }
        }
    }
}
