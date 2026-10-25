import XCTest
import SQLite3
@testable import OpencodeWidgetApp

final class DeepSeekUsageCollectorTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_123)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("deepseek-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testAggregateSumsDeepSeekInputTokensByHour() {
        let hour = Date(timeIntervalSince1970: 0)
        let samples = [
            DeepSeekUsageSample(hour: hour, inputTokens: 100),
            DeepSeekUsageSample(hour: hour, inputTokens: 50),
            DeepSeekUsageSample(hour: hour.addingTimeInterval(3_600), inputTokens: 7)
        ]

        XCTAssertEqual(DeepSeekUsageCollector.aggregate(samples)[hour]?.inputTokens, 150)
        XCTAssertEqual(DeepSeekUsageCollector.aggregate(samples)[hour.addingTimeInterval(3_600)]?.inputTokens, 7)
    }

    func testHourlyTotalsReadsOpenCodeAndHermesAndSumsByHour() throws {
        let openCode = root.appendingPathComponent("opencode.db")
        let hermes = root.appendingPathComponent("hermes.db")
        let currentHour = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3_600) * 3_600)
        let currentHourSeconds = Int64(currentHour.timeIntervalSince1970)
        try makeDatabase(at: openCode, statements: [
            "CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)",
            deepseekOpenCodeInsert(seconds: currentHourSeconds, input: 100, read: 20, write: 5)
        ])
        try makeDatabase(at: hermes, statements: [
            "CREATE TABLE session_model_usage (model TEXT, billing_provider TEXT, input_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, last_seen INTEGER)",
            "INSERT INTO session_model_usage VALUES ('deepseek-flash', 'deepseek', 10, 2, 1, \(currentHourSeconds))"
        ])

        let collector = DeepSeekUsageCollector(
            now: now,
            openCodeDatabasePath: openCode.path,
            hermesDatabasePath: hermes.path,
            codexRoots: []
        )

        let totals = collector.hourlyTotals()
        XCTAssertEqual(totals?[currentHour]?.inputTokens, 100 + 20 + 5 + 10 + 2 + 1)
    }

    func testMissingOptionalOpenCodeDoesNotBlockHermes() throws {
        let hermes = root.appendingPathComponent("hermes.db")
        try makeDatabase(at: hermes, statements: [
            "CREATE TABLE session_model_usage (model TEXT, billing_provider TEXT, input_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, last_seen INTEGER)"
        ])

        let collector = DeepSeekUsageCollector(
            now: now,
            openCodeDatabasePath: root.appendingPathComponent("missing-opencode.db").path,
            hermesDatabasePath: hermes.path,
            codexRoots: []
        )

        XCTAssertEqual(collector.hourlyTotals(), [:])
    }

    func testMissingOptionalHermesDoesNotBlockOpenCode() throws {
        let openCode = root.appendingPathComponent("opencode.db")
        try makeDatabase(at: openCode, statements: [
            "CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT)"
        ])

        let collector = DeepSeekUsageCollector(
            now: now,
            openCodeDatabasePath: openCode.path,
            hermesDatabasePath: root.appendingPathComponent("missing-hermes.db").path,
            codexRoots: []
        )

        XCTAssertEqual(collector.hourlyTotals(), [:])
    }

    private func deepseekOpenCodeInsert(seconds: Int64, input: Int, read: Int, write: Int) -> String {
        let json = #"{"role":"assistant","providerID":"deepseek","tokens":{"input":\#(input),"cache":{"read":\#(read),"write":\#(write)}}}"#
        return "INSERT INTO message (id, session_id, time_created, data) VALUES ('\(UUID().uuidString)', 's', \(seconds * 1000), '\(json)')"
    }

    private func makeDatabase(at url: URL, statements: [String]) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        for statement in statements {
            XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK)
        }
    }
}
