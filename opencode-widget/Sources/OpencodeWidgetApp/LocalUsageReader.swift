import Foundation
import CoreFoundation
import SQLite3
#if canImport(OpencodeWidgetShared)
import OpencodeWidgetShared
#endif

/// Local usage, not account billing or remaining subscription quota. Never reads
/// auth files, logs payloads, or infers a provider from a model's name.
struct LocalUsageReader: Sendable {
    let now: Date
    let openCodeDatabasePath: String
    let hermesDatabasePath: String
    let codexRoots: [URL]
    var codexSessionFiles: @Sendable (URL) -> [URL]? = { root in
        var failed = false
        // An unreadable subtree must not masquerade as a complete source.
        guard let checked = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in failed = true; return false }) else { return nil }
        let files = checked.compactMap { $0 as? URL }
        return failed ? nil : files
    }
    var databaseStep: @Sendable (OpaquePointer?) -> Int32 = sqlite3_step

    init(now: Date = Date(),
         openCodeDatabasePath: String = "\(NSHomeDirectory())/.local/share/opencode/opencode.db",
         hermesDatabasePath: String = "\(NSHomeDirectory())/.hermes/state.db",
         codexRoots: [URL] = [URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/sessions"),
                             URL(fileURLWithPath: "\(NSHomeDirectory())/.codex/archived_sessions")]) {
        self.now = now
        self.openCodeDatabasePath = openCodeDatabasePath
        self.hermesDatabasePath = hermesDatabasePath
        self.codexRoots = codexRoots
    }

    var cutoff: Date {
        Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3_600) * 3_600 - 719 * 3_600)
    }

    func fetch() -> LocalUsageSnapshot {
        LocalUsageSnapshot(from: cutoff, through: now, batches: [readOpenCode(), readCodex(), readHermes()])
    }

    static func provider(_ name: String?, baseURL: String? = nil) -> LocalUsageProvider? {
        let provider: LocalUsageProvider
        switch name?.lowercased() {
        case "openai", "openai-codex": provider = .openAI
        case "deepseek": provider = .deepseek
        default: return nil
        }
        if let baseURL, !baseURL.isEmpty {
            guard let host = URL(string: baseURL)?.host?.lowercased() else { return nil }
            let allowed = provider == .openAI ? ["api.openai.com", "chatgpt.com"] : ["api.deepseek.com"]
            guard allowed.contains(host) else { return nil }
        }
        return provider
    }

    private enum ReadFailure: Error { case unavailable }

    private func database(source: LocalUsageSource, path: String,
                          read: (OpaquePointer) throws -> [LocalUsageObservation]) -> LocalUsageBatch {
        // URI support permits immutable private backups in read-only diagnostics.
        let filePath = path.hasPrefix("file:") ? (URLComponents(string: path)?.path ?? "") : path
        guard FileManager.default.fileExists(atPath: filePath) else { return LocalUsageBatch(source: source, availability: .missing) }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return LocalUsageBatch(source: source, availability: .failed)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)
        do {
            guard sqlite3_exec(handle, "BEGIN", nil, nil, nil) == SQLITE_OK else { throw ReadFailure.unavailable }
            defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
            return LocalUsageBatch(source: source, availability: .available, observations: try read(handle))
        } catch {
            // No SQL, paths, payloads or credentials in diagnostics.
            return LocalUsageBatch(source: source, availability: .failed)
        }
    }

    private func columns(_ table: String, db: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK, let statement else { throw ReadFailure.unavailable }
        defer { sqlite3_finalize(statement) }
        var names = Set<String>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            names.insert(text(statement, 1))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw ReadFailure.unavailable }
        return names
    }

    private func rows(_ sql: String, db: OpaquePointer, divisor: Double,
                      consume: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw ReadFailure.unavailable }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970 * divisor)
        if sqlite3_bind_parameter_count(statement) >= 2 {
            sqlite3_bind_double(statement, 2, now.timeIntervalSince1970 * divisor)
        }
        var status = databaseStep(statement)
        while status == SQLITE_ROW {
            try consume(statement)
            status = databaseStep(statement)
        }
        guard status == SQLITE_DONE else { throw ReadFailure.unavailable }
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
    }

    private func number(_ statement: OpaquePointer, _ index: Int32) throws -> Int64 {
        let type = sqlite3_column_type(statement, index)
        let value = sqlite3_column_double(statement, index)
        guard (type == SQLITE_INTEGER || type == SQLITE_FLOAT), value.isFinite, value >= 0, value < Double(Int64.max) else { throw ReadFailure.unavailable }
        return Int64(value.rounded())
    }

    private func readOpenCode() -> LocalUsageBatch {
        database(source: .openCode, path: openCodeDatabasePath) { db in
            var byID: [String: LocalUsageObservation] = [:]
            var foundTable = false
            // V2 replaces the exact same migrated message ID, never the whole
            // account/session: V1-only messages still contribute.
            for table in ["message", "session_message"] {
                let names = try columns(table, db: db)
                if names.isEmpty { continue }
                foundTable = true
                guard names.isSuperset(of: ["time_created", "data"]), table != "session_message" || names.contains("type") else { throw ReadFailure.unavailable }
                let v2 = table == "session_message"
                let id = names.contains("id") ? "id" : "CAST(rowid AS TEXT)"
                let session = names.contains("session_id") ? "session_id" : "''"
                let role = v2 ? "type" : "json_extract(data, '$.role')"
                let model = v2 ? "$.model.id" : "$.modelID"
                let provider = v2 ? "$.model.providerID" : "$.providerID"
                let sql = """
                    SELECT \(id), \(session), time_created,
                           json_extract(data, '\(provider)'), json_extract(data, '\(model)'),
                           COALESCE(json_extract(data, '$.tokens.input'), 0),
                           COALESCE(json_extract(data, '$.tokens.cache.read'), 0),
                           COALESCE(json_extract(data, '$.tokens.cache.write'), 0),
                           COALESCE(json_extract(data, '$.tokens.output'), 0),
                           COALESCE(json_extract(data, '$.requestID'), json_extract(data, '$.request_id'), ''),
                           COALESCE(json_extract(data, '$.model.baseURL'), json_extract(data, '$.baseURL'), '')
                    FROM \(table) WHERE time_created >= ? AND time_created <= ? AND \(role) = 'assistant'
                    """
                try rows(sql, db: db, divisor: 1_000) { row in
                    let eventID = text(row, 0)
                    // Even an unsupported V2 record owns its migrated V1 ID.
                    byID.removeValue(forKey: eventID)
                    guard let provider = Self.provider(text(row, 3), baseURL: text(row, 10)) else { return }
                    let values = try (5...8).map { try number(row, Int32($0)) }
                    let timestamp = sqlite3_column_double(row, 2) / 1_000
                    guard timestamp.isFinite else { throw ReadFailure.unavailable }
                    byID[eventID] = try observation(source: .openCode, id: eventID, provider: provider,
                        sessionID: text(row, 1), requestID: text(row, 9), timestamp: Date(timeIntervalSince1970: timestamp),
                        model: text(row, 4), values: values)
                }
            }
            guard foundTable else { throw ReadFailure.unavailable }
            return Array(byID.values)
        }
    }

    private func readHermes() -> LocalUsageBatch {
        database(source: .hermes, path: hermesDatabasePath) { db in
            let names = try columns("session_model_usage", db: db)
            guard names.isSuperset(of: ["billing_provider", "model", "last_seen", "input_tokens", "cache_read_tokens", "cache_write_tokens"]) else { throw ReadFailure.unavailable }
            func column(_ name: String, fallback: String = "''") -> String { names.contains(name) ? name : fallback }
            let sql = """
                SELECT \(column("session_id")), billing_provider, model, last_seen,
                       COALESCE(input_tokens,0), COALESCE(cache_read_tokens,0), COALESCE(cache_write_tokens,0),
                       COALESCE(\(column("output_tokens", fallback: "0")),0),
                       \(column("billing_base_url")), \(column("billing_mode")), \(column("task"))
                FROM session_model_usage WHERE last_seen >= ?
                """
            var observations: [LocalUsageObservation] = []
            try rows(sql, db: db, divisor: 1) { row in
                guard let provider = Self.provider(text(row, 1), baseURL: text(row, 8)) else { return }
                let timestamp = sqlite3_column_double(row, 3)
                // A cumulative row may move while the source is being read. If
                // its new last_seen is beyond this snapshot, retain the prior
                // batch rather than delete the old contribution as "missing".
                guard timestamp.isFinite, timestamp <= now.timeIntervalSince1970 else { throw ReadFailure.unavailable }
                let values = try (4...7).map { try number(row, Int32($0)) }
                let id = LocalUsageObservation.key([0, 2, 1, 8, 9, 10].map { text(row, Int32($0)) })
                observations.append(try observation(source: .hermes, id: id, provider: provider,
                    sessionID: text(row, 0), timestamp: Date(timeIntervalSince1970: timestamp), model: text(row, 2), values: values))
            }
            return observations
        }
    }

    private func observation(source: LocalUsageSource, id: String, provider: LocalUsageProvider,
                             sessionID: String, requestID: String = "", timestamp: Date,
                             model: String, values: [Int64]) throws -> LocalUsageObservation {
        let input: Int64
        if provider == .deepseek {
            let (a, overflowA) = values[0].addingReportingOverflow(values[1])
            let (b, overflowB) = a.addingReportingOverflow(values[2])
            guard !overflowA, !overflowB else { throw ReadFailure.unavailable }
            input = b
        } else { input = values[0] }
        return LocalUsageObservation(source: source, id: id, provider: provider, sessionID: sessionID,
            requestID: requestID, hour: timestamp, tokens: Int(input),
            estimatedCostUSD: provider == .openAI ? Self.estimatedCost(model: model, values: values) : nil)
    }

    static func estimatedCost(model: String, values: [Int64]) -> Double? {
        let rates: [String: [Double]] = [
            "gpt-5.6-sol": [4, 0.4, 5, 20], "gpt-5.6-terra": [2, 0.2, 2.5, 12],
            "gpt-5.6-luna": [0.2, 0.02, 0.25, 1.2]
        ]
        guard let rate = rates[model] else { return nil }
        return zip(values, rate).reduce(0) { $0 + Double($1.0) * $1.1 } / 1_000_000
    }

    private struct CodexEvent {
        let session: String
        let timestamp: Date
        let provider: LocalUsageProvider?
        let model: String
        let request: String
        let total: [Int64]?
        let last: [Int64]?
        var signature: String {
            if total == nil, !request.isEmpty {
                return LocalUsageObservation.key([session, provider?.rawValue ?? "", "request", request])
            }
            return LocalUsageObservation.key([session, provider?.rawValue ?? "", model,
                total != nil ? "total" : String(timestamp.timeIntervalSince1970)] + (total ?? last ?? []).map(String.init))
        }
    }

    private func readCodex() -> LocalUsageBatch {
        var available = false
        var visited = Set<String>()
        var events: [CodexEvent] = []
        do {
            let plainDate = ISO8601DateFormatter()
            let fractionalDate = ISO8601DateFormatter()
            fractionalDate.formatOptions.insert(.withFractionalSeconds)
            for root in codexRoots {
                let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
                guard visited.insert(canonical.path).inserted else { continue }
                var directory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &directory) else { continue }
                guard directory.boolValue, let files = codexSessionFiles(canonical) else { throw ReadFailure.unavailable }
                available = true
                for file in files where file.pathExtension == "jsonl" {
                    guard visited.insert(file.standardizedFileURL.resolvingSymlinksInPath().path).inserted else { continue }
                    var session = file.deletingPathExtension().lastPathComponent
                    var declaredProvider: String?
                    var declaredBaseURL: String?
                    var provider: LocalUsageProvider?
                    var model = ""
                    try forEachJSONLine(file) { object in
                        guard let payload = object["payload"] as? [String: Any] else { return }
                        switch object["type"] as? String {
                        case "session_meta":
                            session = payload["id"] as? String ?? payload["session_id"] as? String ?? session
                            declaredProvider = payload["model_provider"] as? String
                            declaredBaseURL = payload["base_url"] as? String
                            provider = Self.provider(declaredProvider, baseURL: declaredBaseURL)
                            model = payload["model"] as? String ?? ""
                        case "turn_context":
                            model = payload["model"] as? String ?? model
                            if let name = payload["model_provider"] as? String {
                                if let previousName = declaredProvider {
                                    let previousFamily = Self.provider(previousName)
                                    let sameFamily = previousFamily != nil && previousFamily == Self.provider(name)
                                    if previousName.lowercased() != name.lowercased(), !sameFamily {
                                        // An explicit provider switch must not inherit
                                        // another provider's canonical/proxy endpoint.
                                        declaredBaseURL = nil
                                    }
                                }
                                declaredProvider = name
                            }
                            if let baseURL = payload["base_url"] as? String { declaredBaseURL = baseURL }
                            // Preserve the endpoint on same-provider/alias turns,
                            // and revalidate URL-only updates as well as name changes.
                            provider = Self.provider(declaredProvider, baseURL: declaredBaseURL)
                        case "event_msg":
                            guard payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any] else { return }
                            guard let date = object["timestamp"] as? String,
                                  let timestamp = fractionalDate.date(from: date) ?? plainDate.date(from: date) else { throw ReadFailure.unavailable }
                            guard timestamp <= now else { return }
                            let total = try tokenValues(info["total_token_usage"])
                            let last = try tokenValues(info["last_token_usage"])
                            guard total != nil || last != nil else { return }
                            events.append(CodexEvent(session: object["session_id"] as? String ?? payload["session_id"] as? String ?? session,
                                timestamp: timestamp, provider: provider, model: info["model"] as? String ?? model,
                                request: payload["request_id"] as? String ?? object["request_id"] as? String ?? "", total: total, last: last))
                        default: break
                        }
                    }
                }
            }
            var highWater: [String: [Int64]] = [:]
            var seen = Set<String>()
            var observations: [LocalUsageObservation] = []
            for event in events.sorted(by: {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                // An incomplete archive copy of the exact same event must not
                // consume the baseline ahead of an explicitly attributed copy.
                if ($0.provider != nil) != ($1.provider != nil) { return $0.provider != nil }
                if $0.model.isEmpty != $1.model.isEmpty { return !$0.model.isEmpty }
                if ($0.last != nil) != ($1.last != nil) { return $0.last != nil }
                return $0.signature < $1.signature
            }) {
                guard seen.insert(event.signature).inserted else { continue }
                let values: [Int64]
                if let total = event.total {
                    if let previous = highWater[event.session] {
                        values = zip(total, previous).map { max(0, $0 - $1) }
                        highWater[event.session] = zip(total, previous).map { max($0.0, $0.1) }
                    } else {
                        values = event.last ?? total
                        highWater[event.session] = total
                    }
                } else { values = event.last! }
                // Read pre-window counters too: the first in-window event is a
                // delta, not the lifetime cumulative total. Replayed totals add 0.
                guard event.timestamp >= cutoff, let provider = event.provider, values.contains(where: { $0 > 0 }) else { continue }
                observations.append(try observation(source: .codex, id: event.signature, provider: provider,
                    sessionID: event.session, requestID: event.request, timestamp: event.timestamp, model: event.model, values: values))
            }
            return LocalUsageBatch(source: .codex, availability: available ? .available : .missing, observations: observations)
        } catch {
            return LocalUsageBatch(source: .codex, availability: .failed)
        }
    }

    private func tokenValues(_ object: Any?) throws -> [Int64]? {
        guard let object else { return nil }
        if object is NSNull { return nil }
        guard let values = object as? [String: Any] else { throw ReadFailure.unavailable }
        return try ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens"].map { key in
            guard let raw = values[key] else { return 0 }
            guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue < Double(Int64.max) else { throw ReadFailure.unavailable }
            return Int64(value.doubleValue.rounded())
        }
    }

    /// Stream files; never retain entire conversation logs or emit their content.
    private func forEachJSONLine(_ file: URL, consume: ([String: Any]) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var buffer = Data()
        func consumeLine(_ line: Data) throws {
            guard !line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) else { return }
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ReadFailure.unavailable }
            try consume(object)
        }
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                try consumeLine(buffer.subdata(in: buffer.startIndex..<newline))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { try consumeLine(buffer) }
    }
}
