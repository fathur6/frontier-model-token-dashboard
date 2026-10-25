import XCTest
import SQLite3
@testable import OpencodeWidgetApp

final class OpenAIUsageCollectorTests: XCTestCase {
    private final class StepSequence: @unchecked Sendable {
        var calls = 0
    }

    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_123)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("openai-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testHourlyTotalCountsUnknownModelsButMarksMixedPriceUnavailable() {
        let hour = Date(timeIntervalSince1970: 0)
        let samples = [
            OpenAIUsageSample(hour: hour, modelID: "gpt-5.6-terra", inputTokens: 1_000_000, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0, source: .openCode, sessionID: "a"),
            OpenAIUsageSample(hour: hour, modelID: "unknown", inputTokens: 1_000_000, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0, source: .codex, sessionID: "b")
        ]

        XCTAssertEqual(OpenAIUsageCollector.aggregate(samples)[hour]?.inputTokens, 2_000_000)
        XCTAssertNil(OpenAIUsageCollector.aggregate(samples)[hour]?.estimatedCostUSD)
        XCTAssertEqual(OpenAIUsageCollector.aggregate([samples[0]])[hour]?.estimatedCostUSD, 2)
    }

    func testDirectCodexSampleWinsOverMirroredHermesSession() {
        let hour = Date(timeIntervalSince1970: 0)
        let codex = OpenAIUsageSample(hour: hour, modelID: "gpt-5.6-luna", inputTokens: 100, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0, source: .codex, sessionID: "shared")
        let hermes = OpenAIUsageSample(hour: hour, modelID: "gpt-5.6-luna", inputTokens: 100, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0, source: .hermes, sessionID: "shared")

        XCTAssertEqual(OpenAIUsageCollector.aggregate([codex, hermes])[hour]?.inputTokens, 100)
    }

    func testDirectOpenCodeSampleWinsOverMirroredHermesSession() {
        let hour = Date(timeIntervalSince1970: 0)
        let openCode = OpenAIUsageSample(hour: hour, modelID: "gpt-5.6-luna", inputTokens: 100, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0, source: .openCode, sessionID: "shared")
        let hermes = OpenAIUsageSample(hour: hour, modelID: "gpt-5.6-luna", inputTokens: 100, cachedInputTokens: 0, cacheWriteTokens: 0, outputTokens: 0, source: .hermes, sessionID: "shared")

        XCTAssertEqual(OpenAIUsageCollector.aggregate([openCode, hermes])[hour]?.inputTokens, 100)
    }

    func testOptionalMissingOpenCodeDoesNotBlockInstalledApps() throws {
        let collector = try makeCollector(openCodePath: root.appendingPathComponent("missing-opencode.db").path)

        XCTAssertEqual(collector.hourlyTotals(), [:])
    }

    func testOptionalMissingCodexDoesNotBlockInstalledApps() throws {
        let collector = try makeCollector(codexRoots: [root.appendingPathComponent("missing-codex")])

        XCTAssertEqual(collector.hourlyTotals(), [:])
    }

    func testOptionalMissingHermesDoesNotBlockInstalledApps() throws {
        let collector = try makeCollector(hermesPath: root.appendingPathComponent("missing-hermes.db").path)

        XCTAssertEqual(collector.hourlyTotals(), [:])
    }

    func testHourlyTotalsAreUnavailableWhenCodexSessionFileCannotBeRead() throws {
        let codexRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: codexRoot.appendingPathComponent("session.jsonl"))
        let collector = try makeCollector(codexRoots: [codexRoot])

        XCTAssertNil(collector.hourlyTotals())
    }

    func testHourlyTotalsAreUnavailableWhenCodexSessionEnumeratorCannotBeCreated() throws {
        let codexRoot = root.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let collector = try makeCollector(
            codexRoots: [codexRoot],
            codexSessionFiles: { _ in nil }
        )

        XCTAssertNil(collector.hourlyTotals())
    }

    func testHourlyTotalsAreUnavailableWhenSQLiteIterationDoesNotFinish() throws {
        let sequence = StepSequence()
        let collector = try makeCollector(
            openCodeStatements: [
                "INSERT INTO message VALUES (1800000000000, 'direct', '{\"role\":\"assistant\",\"providerID\":\"openai\",\"modelID\":\"gpt-5.6-terra\",\"tokens\":{\"input\":100,\"cache\":{\"read\":0,\"write\":0},\"output\":0}}')"
            ],
            databaseStep: { statement in
                sequence.calls += 1
                return sequence.calls == 1 ? sqlite3_step(statement) : SQLITE_ERROR
            }
        )

        XCTAssertNil(collector.hourlyTotals())
    }

    private func makeCollector(
        openCodePath: String? = nil,
        hermesPath: String? = nil,
        codexRoots: [URL]? = nil,
        openCodeStatements: [String] = [],
        codexSessionFiles: @escaping @Sendable (URL) -> [URL]? = { root in
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return nil }
            return enumerator.compactMap { $0 as? URL }
        },
        databaseStep: @escaping @Sendable (OpaquePointer?) -> Int32 = sqlite3_step
    ) throws -> OpenAIUsageCollector {
        let openCode = root.appendingPathComponent("opencode.db")
        let hermes = root.appendingPathComponent("hermes.db")
        try makeDatabase(at: openCode, statements: [
            "CREATE TABLE message (time_created INTEGER, session_id TEXT, data TEXT)"
        ] + openCodeStatements)
        try makeDatabase(at: hermes, statements: [
            "CREATE TABLE session_model_usage (last_seen INTEGER, session_id TEXT, model TEXT, input_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, output_tokens INTEGER, billing_provider TEXT)"
        ])
        let codex = root.appendingPathComponent("codex-empty")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        return OpenAIUsageCollector(
            now: now,
            openCodeDatabasePath: openCodePath ?? openCode.path,
            hermesDatabasePath: hermesPath ?? hermes.path,
            codexRoots: codexRoots ?? [codex],
            codexSessionFiles: codexSessionFiles,
            databaseStep: databaseStep
        )
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
