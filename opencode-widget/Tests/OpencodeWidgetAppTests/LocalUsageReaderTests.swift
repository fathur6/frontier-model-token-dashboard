import XCTest
import SQLite3
@testable import OpencodeWidgetApp
import OpencodeWidgetShared

final class LocalUsageReaderTests: XCTestCase {
    private var root: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_123)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DAF-26-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func reader() -> LocalUsageReader {
        LocalUsageReader(now: now, openCodeDatabasePath: root.appendingPathComponent("open.db").path,
            hermesDatabasePath: root.appendingPathComponent("hermes.db").path,
            codexRoots: [root.appendingPathComponent("sessions"), root.appendingPathComponent("archive")])
    }

    private func database(_ name: String, _ statements: [String]) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(root.appendingPathComponent(name).path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        for sql in statements { XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK) }
    }

    private func codex(_ objects: [[String: Any]]) throws { try codex("sessions/a.jsonl", objects) }

    private func codex(_ name: String, _ objects: [[String: Any]]) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = Data()
        for object in objects { text.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])); text.append(10) }
        try text.write(to: file)
    }

    private func meta(_ session: String, provider: String? = "openai", baseURL: String? = nil) -> [String: Any] {
        var payload: [String: Any] = ["id": session]
        payload["model_provider"] = provider
        payload["base_url"] = baseURL
        return ["type": "session_meta", "payload": payload]
    }
    private func context(_ model: String = "gpt-6.1-sol", provider: String? = nil, baseURL: String? = nil) -> [String: Any] {
        var payload = ["model": model]
        payload["model_provider"] = provider
        payload["base_url"] = baseURL
        return ["type": "turn_context", "payload": payload]
    }
    private func count(_ date: Date, total: Int? = nil, last: Int? = nil, cached: Int = 0, request: String? = nil) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        var info: [String: Any] = [:]
        if let total { info["total_token_usage"] = ["input_tokens": total, "cached_input_tokens": cached] }
        if let last { info["last_token_usage"] = ["input_tokens": last] }
        var payload: [String: Any] = ["type": "token_count", "info": info]
        payload["request_id"] = request
        return ["type": "event_msg", "timestamp": formatter.string(from: date), "payload": payload]
    }

    func testV2CoexistsWithV1WithoutDoublingMigratedIDsAndRetainsV1Only() throws {
        let time = Int64(now.timeIntervalSince1970 * 1_000) - 1_000
        try database("open.db", [
            "CREATE TABLE message(id TEXT,session_id TEXT,time_created INTEGER,data TEXT)",
            "CREATE TABLE session_message(id TEXT,session_id TEXT,type TEXT,time_created INTEGER,data TEXT)",
            "INSERT INTO message VALUES('shared','session',\(time),'{\"role\":\"assistant\",\"providerID\":\"openai\",\"modelID\":\"gpt-6.1-sol\",\"tokens\":{\"input\":100}}')",
            "INSERT INTO message VALUES('legacy-only','other',\(time),'{\"role\":\"assistant\",\"providerID\":\"deepseek\",\"tokens\":{\"input\":20,\"cache\":{\"read\":3,\"write\":2}}}')",
            "INSERT INTO session_message VALUES('shared','session','assistant',\(time),'{\"model\":{\"providerID\":\"openai\",\"id\":\"gpt-6.1-sol\"},\"tokens\":{\"input\":120,\"cache\":{\"read\":40}}}')",
            "INSERT INTO session_message VALUES('user','session','user',\(time),'{\"tokens\":{\"input\":999}}')",
            "INSERT INTO session_message VALUES('custom','custom','assistant',\(time),'{\"model\":{\"providerID\":\"custom\",\"id\":\"gpt-6.1-sol\"},\"tokens\":{\"input\":999}}')"
        ])
        let result = reader().fetch()
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.observations.count, 2)
        XCTAssertEqual(result.observations.first { $0.provider == .openAI }?.tokens, 120)
        XCTAssertNil(result.observations.first { $0.provider == .openAI }?.estimatedCostUSD)
        XCTAssertEqual(result.observations.first { $0.provider == .deepseek }?.tokens, 25)
    }

    func testV2OnlyDatabaseWorksAndCustomBaseURLDoesNotBecomeOpenAI() throws {
        let time = Int64(now.timeIntervalSince1970 * 1_000) - 1_000
        try database("open.db", [
            "CREATE TABLE session_message(id TEXT,session_id TEXT,type TEXT,time_created INTEGER,data TEXT)",
            "INSERT INTO session_message VALUES('a','session','assistant',\(time),'{\"model\":{\"providerID\":\"openai\",\"id\":\"unpriced\"},\"tokens\":{\"input\":10}}')",
            "INSERT INTO session_message VALUES('b','session','assistant',\(time),'{\"model\":{\"providerID\":\"openai\",\"id\":\"unpriced\",\"baseURL\":\"https://other.example/v1\"},\"tokens\":{\"input\":999}}')"
        ])
        XCTAssertEqual(reader().fetch().observations.map(\.tokens), [10])
    }

    func testRealCodexMetadataFractionalDatesRoutesBothProvidersAndRejectsUnknownOrCustom() throws {
        let t = now.addingTimeInterval(-60)
        try codex([meta("openai-session"), context(), count(t, total: 100, last: 10)])
        try codex("sessions/ds.jsonl", [meta("deepseek-session", provider: "deepseek"), context("deepseek-flash"), count(t, total: 20, cached: 5)])
        try codex("sessions/unknown.jsonl", [meta("unknown", provider: nil), context(), count(t, total: 999)])
        try codex("sessions/custom.jsonl", [meta("custom", provider: "openai", baseURL: "https://proxy.example/v1"), context(), count(t, total: 999)])
        let result = reader().fetch()
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.observations.filter { $0.provider == .openAI }.map(\.tokens), [10])
        XCTAssertEqual(result.observations.filter { $0.provider == .deepseek }.map(\.tokens), [25])
        XCTAssertNil(result.observations.first { $0.provider == .openAI }?.estimatedCostUSD)
    }

    func testCodexCumulativeBaselineBeforeWindowArchiveCopiesAndReplayedTotals() throws {
        let cutoff = reader().cutoff
        let events = [meta("same-session"), context(), count(cutoff.addingTimeInterval(-1), total: 100, last: 5),
            count(cutoff.addingTimeInterval(1), total: 140, last: 40),
            count(cutoff.addingTimeInterval(2), total: 140, last: 40),
            count(cutoff.addingTimeInterval(3), total: 160, last: 20)]
        try codex(events)
        try codex("archive/copy.jsonl", events)
        let result = reader().fetch()
        XCTAssertEqual(result.observations.reduce(0) { $0 + $1.tokens }, 60)
        XCTAssertEqual(result.observations.count, 2)
    }

    func testCodexCustomSessionBaseURLSurvivesRepeatedSameProviderContexts() throws {
        let t = now.addingTimeInterval(-60)
        let initialNames: [String?] = [nil,"openai"]
        for initialName in initialNames {
            try codex([meta("proxy-session",provider:initialName,baseURL:"https://proxy.example/v1"),
                context(provider:"openai"),count(t,total:100,last:100),
                context(provider:"OPENAI"),count(t.addingTimeInterval(1),total:150,last:50),
                context(provider:"openai-codex"),count(t.addingTimeInterval(2),total:200,last:50)])
            let result = reader().fetch()
            XCTAssertFalse(result.hasFailures)
            XCTAssertTrue(result.observations.isEmpty)
        }
    }

    func testCodexBaseURLOnlyChangeInvalidatesProviderAndPersistsAcrossLaterContexts() throws {
        let t = now.addingTimeInterval(-60)
        try codex([meta("changing-endpoint",baseURL:"https://api.openai.com/v1"),
            context(),count(t,total:100,last:100),
            context(baseURL:"https://proxy.example/v1"),count(t.addingTimeInterval(1),total:150,last:50),
            context(provider:"openai"),count(t.addingTimeInterval(2),total:200,last:50)])
        let result = reader().fetch()
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.observations.map(\.tokens),[100])
        XCTAssertEqual(result.observations.map(\.provider),[.openAI])
    }

    func testCodexExplicitProviderSwitchWithoutURLClearsPreviousProviderEndpoint() throws {
        let t = now.addingTimeInterval(-60)
        for oldURL in ["https://api.openai.com/v1","https://proxy.example/v1"] {
            try codex([meta("provider-switch",baseURL:oldURL),context(),count(t,total:100,last:100),
                context("deepseek-flash",provider:"deepseek"),count(t.addingTimeInterval(1),total:140,last:40)])
            let result = reader().fetch()
            XCTAssertFalse(result.hasFailures)
            XCTAssertEqual(result.observations.filter{$0.provider == .deepseek}.map(\.tokens),[40])
            XCTAssertEqual(result.observations.filter{$0.provider == .openAI}.reduce(0){$0+$1.tokens},oldURL.contains("proxy") ? 0 : 100)
        }
    }

    func testCodexIndependentSessionsSharingProviderKeepIdenticalCounters() throws {
        let t = now.addingTimeInterval(-60)
        for session in ["one", "two"] {
            try codex("sessions/\(session).jsonl", [meta(session), context(), count(t, total: 100, last: 100)])
        }
        XCTAssertEqual(reader().fetch().observations.reduce(0) { $0 + $1.tokens }, 200)
    }

    func testAttributedArchiveCopyWinsOverIncompleteSameEventMetadata() throws {
        let t = now.addingTimeInterval(-60)
        try codex([meta("one",provider:nil),context(),count(t,total:100,last:100)])
        try codex("archive/copy.jsonl",[meta("one"),context(),count(t,total:100,last:100)])
        XCTAssertEqual(reader().fetch().observations.reduce(0){$0+$1.tokens},100)
    }

    func testFirstCumulativeArchiveReplayPrefersObservedLastUsageOverUnattributedLifetimeTotal() throws {
        let t = now.addingTimeInterval(-60)
        try codex([meta("one"),context(),count(t,total:1_000)])
        try codex("archive/copy.jsonl",[meta("one"),context(),count(t,total:1_000,last:100)])
        XCTAssertEqual(reader().fetch().observations.reduce(0){$0+$1.tokens},100)
    }

    func testCodexCounterDeltasCrossHoursAndProviderSwitchWithoutReassigningEarlierUsage() throws {
        let old = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970/3_600)*3_600 - 10)
        try codex([meta("switching"), context(), count(old,total:100,last:100),
            context("deepseek-flash",provider:"deepseek"), count(old.addingTimeInterval(20),total:140,last:40)])
        let observations = reader().fetch().observations
        XCTAssertEqual(observations.first{$0.provider == .openAI}?.tokens,100)
        XCTAssertEqual(observations.first{$0.provider == .deepseek}?.tokens,40)
        XCTAssertNotEqual(observations.first{$0.provider == .openAI}?.hour,observations.first{$0.provider == .deepseek}?.hour)
    }

    func testMalformedTokenTimestampAndNegativeCountersFailRatherThanReplaceHistoryWithZero() throws {
        var invalidDate = count(now.addingTimeInterval(-1),total:10)
        invalidDate["timestamp"] = "invalid"
        try codex([meta("a"),context(),invalidDate])
        XCTAssertTrue(reader().fetch().hasFailures)
        try codex([meta("a"),context(),count(now.addingTimeInterval(-1),total:-1)])
        XCTAssertTrue(reader().fetch().hasFailures)
    }

    func testCodexLastOnlyExactReplayAndExplicitRequestIdentityDeduplicate() throws {
        let t = now.addingTimeInterval(-60)
        let events = [meta("one"), context(), count(t, last: 10, request: "request-a"), count(t, last: 10, request: "request-a"),
            count(t.addingTimeInterval(1), last: 10, request: "request-a"), count(t, last: 10, request: "request-b")]
        try codex(events)
        XCTAssertEqual(reader().fetch().observations.reduce(0) { $0 + $1.tokens }, 20)
    }

    func testMalformedPresentSourceFailsButAbsentOptionalAppsDoNotBlockUsage() throws {
        try codex([meta("a"), context(), count(now.addingTimeInterval(-1), last: 50)])
        var result = reader().fetch()
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.observations.map(\.tokens), [50])
        try database("open.db", ["CREATE TABLE unrelated(x INTEGER)"])
        result = reader().fetch()
        XCTAssertTrue(result.hasFailures)
        XCTAssertEqual(result.batches.first { $0.source == .openCode }?.availability, .failed)
        XCTAssertEqual(result.observations.map(\.tokens), [50])
        try Data("malformed\n".utf8).write(to: root.appendingPathComponent("sessions/broken.jsonl"))
        result = reader().fetch()
        XCTAssertEqual(result.batches.first { $0.source == .codex }?.availability, .failed)
        XCTAssertTrue(result.observations.isEmpty)
    }

    func testHermesAttributionAndExactSessionMirrorDeduplicationNotAccountDeduplication() throws {
        try database("hermes.db", [
            "CREATE TABLE session_model_usage(session_id TEXT,model TEXT,billing_provider TEXT,billing_base_url TEXT,billing_mode TEXT,task TEXT,last_seen REAL,input_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER,output_tokens INTEGER)",
            "INSERT INTO session_model_usage VALUES('direct','gpt-6.1-sol','openai-codex','','oauth','',\(now.timeIntervalSince1970 - 1),100,0,0,0)",
            "INSERT INTO session_model_usage VALUES('independent','gpt-6.1-sol','openai-codex','','oauth','',\(now.timeIntervalSince1970 - 1),50,0,0,0)",
            "INSERT INTO session_model_usage VALUES('ds','deepseek-flash','deepseek','https://api.deepseek.com','api','',\(now.timeIntervalSince1970 - 1),10,3,2,0)",
            "INSERT INTO session_model_usage VALUES('proxy','gpt-6.1-sol','openai','https://other.example/v1','api','',\(now.timeIntervalSince1970 - 1),999,0,0,0)"
        ])
        try codex([meta("direct"), context(), count(now.addingTimeInterval(-2), last: 100)])
        let result = reader().fetch()
        XCTAssertFalse(result.hasFailures)
        XCTAssertEqual(result.observations.filter { $0.provider == .openAI }.reduce(0) { $0 + $1.tokens }, 150)
        XCTAssertEqual(result.observations.filter { $0.provider == .deepseek }.map(\.tokens), [15])
    }

    func testHermesRowMovingBeyondCapturedNowIsUnavailableInsteadOfAFalseEmptySnapshot() throws {
        try database("hermes.db",[
            "CREATE TABLE session_model_usage(session_id TEXT,model TEXT,billing_provider TEXT,last_seen REAL,input_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER)",
            "INSERT INTO session_model_usage VALUES('stable','gpt-6.1-sol','openai-codex',\(now.timeIntervalSince1970+1),100,0,0)"
        ])
        let result = reader().fetch()
        XCTAssertEqual(result.batches.first{$0.source == .hermes}?.availability,.failed)
        XCTAssertTrue(result.observations.isEmpty)
    }
}
