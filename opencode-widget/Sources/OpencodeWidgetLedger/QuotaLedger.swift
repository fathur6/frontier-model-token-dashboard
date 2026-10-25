import Foundation
import SQLite3
#if canImport(OpencodeWidgetShared)
import OpencodeWidgetShared
#endif

public final class QuotaLedger {
    private var db: OpaquePointer?
    public private(set) var migrationError: String?

    public init(path: String) {
        var handle: OpaquePointer?
        if sqlite3_open(path, &handle) == SQLITE_OK, let handle {
            db = handle
            if !createSchema() {
                migrationError = "Quota ledger schema migration failed."
                NSLog("Quota ledger schema migration failed.")
                sqlite3_close(handle)
                db = nil
            }
        } else {
            sqlite3_close(handle)
            db = nil
        }
    }

    public static func open(path: String) -> QuotaLedger {
        QuotaLedger(path: path)
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func createSchema() -> Bool {
        guard let db, sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var committed = false
        defer {
            if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS quota_snapshots(
          hour TEXT PRIMARY KEY,
          deepseek_usd REAL,
          openai_percent REAL,
          source TEXT,
          recorded_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_quota_snapshots_hour ON quota_snapshots(hour);
        CREATE TABLE IF NOT EXISTS quota_month_mark(
          yyyy_mm TEXT PRIMARY KEY,
          emailed_at TEXT
        );
        CREATE TABLE IF NOT EXISTS usage_observations(
          source TEXT NOT NULL, id TEXT NOT NULL, provider TEXT NOT NULL,
          session_id TEXT NOT NULL, request_id TEXT NOT NULL,
          hour TEXT NOT NULL, tokens INTEGER NOT NULL, cost REAL,
          PRIMARY KEY(source,id)
        );
        CREATE TABLE IF NOT EXISTS usage_managed_hours(
          hour TEXT NOT NULL, provider TEXT NOT NULL, PRIMARY KEY(hour,provider)
        );
        CREATE TABLE IF NOT EXISTS usage_source_state(
          source TEXT PRIMARY KEY, observed_through REAL NOT NULL
        );
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(quota_snapshots)", -1, &statement, nil) == SQLITE_OK else { return false }
        var columns = Set<String>()
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            if let name = sqliteText(statement, index: 1) { columns.insert(name.lowercased()) }
            status = sqlite3_step(statement)
        }
        let finalized = sqlite3_finalize(statement)
        guard status == SQLITE_DONE, finalized == SQLITE_OK else { return false }
        // Static identifiers only. No table recreation, data backfill or retention
        // occurs during migration; old rows receive NULL for every added field.
        let additions = [
            ("deepseek_input_tokens", "INTEGER"),
            ("openai_input_tokens", "INTEGER"),
            ("openai_estimated_cost_usd", "REAL"),
            ("openai_five_hour_percent", "REAL"),
            ("openai_five_hour_reset_at", "REAL")
        ]
        for (name, type) in additions where !columns.contains(name) {
            guard sqlite3_exec(db, "ALTER TABLE quota_snapshots ADD COLUMN \(name) \(type)", nil, nil, nil) == SQLITE_OK else { return false }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { return false }
        committed = true
        return true
    }

    private func flooredHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 3_600) * 3_600)
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func isoFromString(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s)
    }

    private func sqliteText(_ values: OpaquePointer?, index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(values, index) else { return nil }
        return String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
    }

    private func bindText(_ stmt: OpaquePointer?, index: Int32, _ value: String?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        value.withCString { cstr in
            sqlite3_bind_text(stmt, index, cstr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    public func record(
        hour: Date,
        deepseekUSD: Double?,
        openaiPercent: Double?,
        deepseekInputTokens: Int? = nil,
        openAIInputTokens: Int? = nil,
        openAIEstimatedCostUSD: Double? = nil,
        fiveHourRemainingPercent: Double? = nil,
        fiveHourResetDate: Date? = nil,
        source: String
    ) {
        guard let db else { return }
        let h = flooredHour(hour)
        let sql = """
        INSERT INTO quota_snapshots(hour, deepseek_usd, openai_percent, deepseek_input_tokens, openai_input_tokens, openai_estimated_cost_usd, source, recorded_at, openai_five_hour_percent, openai_five_hour_reset_at)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(hour) DO UPDATE SET
          deepseek_usd = COALESCE(excluded.deepseek_usd, quota_snapshots.deepseek_usd),
          openai_percent = COALESCE(excluded.openai_percent, quota_snapshots.openai_percent),
          deepseek_input_tokens = COALESCE(excluded.deepseek_input_tokens, quota_snapshots.deepseek_input_tokens),
          openai_input_tokens = COALESCE(excluded.openai_input_tokens, quota_snapshots.openai_input_tokens),
           openai_estimated_cost_usd = CASE WHEN excluded.openai_input_tokens IS NOT NULL
             THEN excluded.openai_estimated_cost_usd
             ELSE COALESCE(excluded.openai_estimated_cost_usd, quota_snapshots.openai_estimated_cost_usd) END,
          openai_five_hour_percent = COALESCE(excluded.openai_five_hour_percent, quota_snapshots.openai_five_hour_percent),
          openai_five_hour_reset_at = COALESCE(excluded.openai_five_hour_reset_at, quota_snapshots.openai_five_hour_reset_at),
          source = excluded.source,
          recorded_at = excluded.recorded_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, index: 1, iso(h))
        if let d = deepseekUSD {
            sqlite3_bind_double(stmt, 2, d)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        if let p = openaiPercent {
            sqlite3_bind_double(stmt, 3, p)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let t = deepseekInputTokens {
            sqlite3_bind_int64(stmt, 4, sqlite3_int64(t))
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        if let t = openAIInputTokens {
            sqlite3_bind_int64(stmt, 5, sqlite3_int64(t))
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        if let c = openAIEstimatedCostUSD {
            sqlite3_bind_double(stmt, 6, c)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        bindText(stmt, index: 7, source)
        bindText(stmt, index: 8, iso(Date()))
        if let percent = fiveHourRemainingPercent {
            sqlite3_bind_double(stmt, 9, percent)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        if let reset = fiveHourResetDate {
            sqlite3_bind_double(stmt, 10, reset.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 10)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    public func prune(retentionMonths: Int = 12, now: Date = Date()) {
        guard let db else { return }
        var comp = DateComponents()
        comp.month = -retentionMonths
        guard let cutoff = Calendar.current.date(byAdding: comp, to: now) else { return }
        let startOfCutoffMonth = Calendar.current.dateInterval(of: .month, for: cutoff)?.start ?? cutoff
        let sql = "DELETE FROM quota_snapshots WHERE hour < ?"
        let cutoffStr = iso(startOfCutoffMonth)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, index: 1, cutoffStr)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        for table in ["usage_observations", "usage_managed_hours"] {
            try? usageWrite("DELETE FROM \(table) WHERE hour < ?") { bindText($0, index: 1, cutoffStr) }
        }
    }

    public func rows(from: Date, to: Date) -> [QuotaSnapshotRow] {
        guard let db else { return [] }
        let sql = "SELECT hour, deepseek_usd, openai_percent, deepseek_input_tokens, openai_input_tokens, openai_estimated_cost_usd, source, openai_five_hour_percent, openai_five_hour_reset_at FROM quota_snapshots WHERE hour >= ? AND hour < ? ORDER BY hour ASC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, index: 1, iso(from))
        bindText(stmt, index: 2, iso(to))
        var result: [QuotaSnapshotRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hstr = sqliteText(stmt, index: 0),
                  let h = isoFromString(hstr) else { continue }
            let d: Double? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
            let p: Double? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            let dt: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3))
            let ot: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 4))
            let c: Double? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
            let src = sqliteText(stmt, index: 6) ?? ""
            let fivePercent: Double? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7)
            let fiveReset: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            result.append(QuotaSnapshotRow(hour: h, deepseekUSD: d, openaiPercent: p, deepseekInputTokens: dt, openAIInputTokens: ot, openAIEstimatedCostUSD: c, fiveHourRemainingPercent: fivePercent, fiveHourResetDate: fiveReset, source: src))
        }
        sqlite3_finalize(stmt)
        return result
    }

    public func monthRows(month: Date) -> [QuotaSnapshotRow] {
        guard let interval = Calendar.current.dateInterval(of: .month, for: month) else { return [] }
        return rows(from: interval.start, to: interval.end)
    }

    public func recentSnapshots(limit: Int) -> [QuotaSnapshotRow] {
        guard let db else { return [] }
        let sql = "SELECT hour, deepseek_usd, openai_percent, deepseek_input_tokens, openai_input_tokens, openai_estimated_cost_usd, source, openai_five_hour_percent, openai_five_hour_reset_at FROM quota_snapshots ORDER BY hour DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int(stmt, 1, Int32(max(0, limit)))
        var result: [QuotaSnapshotRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let hstr = sqliteText(stmt, index: 0),
                  let h = isoFromString(hstr) else { continue }
            let d: Double? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
            let p: Double? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
            let dt: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 3))
            let ot: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 4))
            let c: Double? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5)
            let src = sqliteText(stmt, index: 6) ?? ""
            let fivePercent: Double? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7)
            let fiveReset: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
            result.append(QuotaSnapshotRow(hour: h, deepseekUSD: d, openaiPercent: p, deepseekInputTokens: dt, openAIInputTokens: ot, openAIEstimatedCostUSD: c, fiveHourRemainingPercent: fivePercent, fiveHourResetDate: fiveReset, source: src))
        }
        sqlite3_finalize(stmt)
        return result.reversed()
    }

    public func count() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM quota_snapshots", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        var n = 0
        if sqlite3_step(stmt) == SQLITE_ROW { n = Int(sqlite3_column_int64(stmt, 0)) }
        sqlite3_finalize(stmt)
        return n
    }

    public func activeOpenAIEstimatedCost(from start: Date, through end: Date) -> Double? {
        guard let db else { return nil }
        let sql = """
            SELECT CASE WHEN SUM(CASE WHEN openai_input_tokens IS NOT NULL AND openai_estimated_cost_usd IS NULL THEN 1 ELSE 0 END) > 0
              THEN NULL ELSE COALESCE(SUM(openai_estimated_cost_usd), 0) END
            FROM quota_snapshots WHERE hour >= ? AND hour <= ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bindText(statement, index: 1, iso(start))
        bindText(statement, index: 2, iso(end))
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, 0)
    }

    /// Reconcile complete source snapshots, not incremental hourly additions.
    /// Failed/missing sources keep their last durable contributions. In particular
    /// a Hermes cumulative row that changes last_seen MOVES instead of doubling.
    /// All provenance and hourly projections commit together, or neither changes.
    @discardableResult
    public func reconcileUsage(_ snapshot: LocalUsageSnapshot) -> Bool {
        guard let db, snapshot.anyAvailable,
              snapshot.from <= snapshot.through,
              Set(snapshot.batches.map(\.source)).count == snapshot.batches.count,
              sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        do {
            for batch in snapshot.batches where batch.availability == .available {
                var latest = -Double.greatestFiniteMagnitude
                try usageRead("SELECT source,observed_through FROM usage_source_state") { stmt in
                    if sqliteText(stmt, index: 0) == batch.source.rawValue { latest = sqlite3_column_double(stmt, 1) }
                }
                // A slow older refresh must not replace a newer source snapshot.
                if snapshot.through.timeIntervalSince1970 < latest { continue }
                try usageWrite("DELETE FROM usage_observations WHERE source=? AND hour>=? AND hour<=?") { stmt in
                    bindText(stmt, index: 1, batch.source.rawValue)
                    bindText(stmt, index: 2, iso(flooredHour(snapshot.from)))
                    bindText(stmt, index: 3, iso(flooredHour(snapshot.through)))
                }
                for observation in batch.observations {
                    guard observation.source == batch.source, !observation.id.isEmpty,
                          observation.tokens >= 0, observation.hour.timeIntervalSince1970.isFinite,
                          observation.hour >= flooredHour(snapshot.from), observation.hour <= snapshot.through,
                          observation.estimatedCostUSD.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw UsageWriteFailure.invalid }
                    try usageWrite("""
                        INSERT INTO usage_observations(source,id,provider,session_id,request_id,hour,tokens,cost)
                        VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(source,id) DO UPDATE SET
                          provider=excluded.provider,session_id=excluded.session_id,request_id=excluded.request_id,
                          hour=excluded.hour,tokens=excluded.tokens,cost=excluded.cost
                        """) { stmt in
                        bindText(stmt, index: 1, observation.source.rawValue)
                        bindText(stmt, index: 2, observation.id)
                        bindText(stmt, index: 3, observation.provider.rawValue)
                        bindText(stmt, index: 4, observation.sessionID)
                        bindText(stmt, index: 5, observation.requestID)
                        bindText(stmt, index: 6, iso(observation.hour))
                        sqlite3_bind_int64(stmt, 7, Int64(observation.tokens))
                        if let cost = observation.estimatedCostUSD { sqlite3_bind_double(stmt, 8, cost) }
                    }
                }
                try usageWrite("INSERT INTO usage_source_state(source,observed_through) VALUES(?,?) ON CONFLICT(source) DO UPDATE SET observed_through=excluded.observed_through") { stmt in
                    bindText(stmt, index: 1, batch.source.rawValue)
                    sqlite3_bind_double(stmt, 2, snapshot.through.timeIntervalSince1970)
                }
            }
            try projectUsage(preserveLegacy: snapshot.hasFailures)
            guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw UsageWriteFailure.invalid }
            committed = true
            return true
        } catch { return false }
    }

    private enum UsageWriteFailure: Error { case invalid }

    private func usageWrite(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let db else { throw UsageWriteFailure.invalid }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw UsageWriteFailure.invalid }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw UsageWriteFailure.invalid }
    }

    private func usageRead(_ sql: String, row: (OpaquePointer) throws -> Void) throws {
        guard let db else { throw UsageWriteFailure.invalid }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw UsageWriteFailure.invalid }
        defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            try row(statement)
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw UsageWriteFailure.invalid }
    }

    private func projectUsage(preserveLegacy: Bool) throws {
        struct Key: Hashable { let hour: String; let provider: LocalUsageProvider }
        struct Total { var tokens = 0; var cost: Double? = 0 }
        var observations: [LocalUsageObservation] = []
        try usageRead("SELECT source,id,provider,session_id,request_id,hour,tokens,cost FROM usage_observations") { stmt in
            guard let source = LocalUsageSource(rawValue: sqliteText(stmt, index: 0) ?? ""),
                  let provider = LocalUsageProvider(rawValue: sqliteText(stmt, index: 2) ?? ""),
                  let hour = isoFromString(sqliteText(stmt, index: 5) ?? "") else { throw UsageWriteFailure.invalid }
            observations.append(LocalUsageObservation(source: source, id: sqliteText(stmt, index: 1) ?? "", provider: provider,
                sessionID: sqliteText(stmt, index: 3) ?? "", requestID: sqliteText(stmt, index: 4) ?? "", hour: hour,
                tokens: Int(sqlite3_column_int64(stmt, 6)),
                estimatedCostUSD: sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7)))
        }
        var totals: [Key: Total] = [:]
        for observation in LocalUsageSnapshot.deduplicated(observations) {
            let key = Key(hour: iso(observation.hour), provider: observation.provider)
            var total = totals[key] ?? Total()
            let (tokens, overflow) = total.tokens.addingReportingOverflow(observation.tokens)
            guard !overflow else { throw UsageWriteFailure.invalid }
            total.tokens = tokens
            if let previous = total.cost, let cost = observation.estimatedCostUSD {
                total.cost = previous + cost
            } else { total.cost = nil }
            totals[key] = total
        }
        var managed = Set<Key>()
        try usageRead("SELECT hour,provider FROM usage_managed_hours") { stmt in
            guard let provider = LocalUsageProvider(rawValue: sqliteText(stmt, index: 1) ?? "") else { throw UsageWriteFailure.invalid }
            managed.insert(Key(hour: sqliteText(stmt, index: 0) ?? "", provider: provider))
        }
        var existing: [Key: Int] = [:]
        try usageRead("SELECT hour,deepseek_input_tokens,openai_input_tokens FROM quota_snapshots") { stmt in
            let hour = sqliteText(stmt, index: 0) ?? ""
            if sqlite3_column_type(stmt, 1) != SQLITE_NULL { existing[Key(hour: hour, provider: .deepseek)] = Int(sqlite3_column_int64(stmt, 1)) }
            if sqlite3_column_type(stmt, 2) != SQLITE_NULL { existing[Key(hour: hour, provider: .openAI)] = Int(sqlite3_column_int64(stmt, 2)) }
        }
        for key in Set(totals.keys).union(managed) {
            let total = totals[key] ?? Total()
            if !managed.contains(key), let old = existing[key] {
                // Legacy rows have no source provenance. Never reduce an opaque
                // complete total on migration, or adopt it during a failed read.
                if preserveLegacy || old > total.tokens { continue }
            }
            let tokenColumn = key.provider == .openAI ? "openai_input_tokens" : "deepseek_input_tokens"
            let costColumns = key.provider == .openAI ? ",openai_estimated_cost_usd" : ""
            let costValue = key.provider == .openAI ? ",?" : ""
            let costUpdate = key.provider == .openAI ? ",openai_estimated_cost_usd=excluded.openai_estimated_cost_usd" : ""
            try usageWrite("""
                INSERT INTO quota_snapshots(hour,\(tokenColumn),source,recorded_at\(costColumns)) VALUES(?,?,'usage',?\(costValue))
                ON CONFLICT(hour) DO UPDATE SET \(tokenColumn)=excluded.\(tokenColumn)\(costUpdate)
                """) { stmt in
                bindText(stmt, index: 1, key.hour)
                sqlite3_bind_int64(stmt, 2, Int64(total.tokens))
                bindText(stmt, index: 3, iso(Date()))
                if key.provider == .openAI, let cost = total.cost { sqlite3_bind_double(stmt, 4, cost) }
            }
            try usageWrite("INSERT OR IGNORE INTO usage_managed_hours(hour,provider) VALUES(?,?)") { stmt in
                bindText(stmt, index: 1, key.hour)
                bindText(stmt, index: 2, key.provider.rawValue)
            }
        }
    }

    public func markMonthEmailed(yyyyMM: String) {
        guard let db else { return }
        let sql = "INSERT INTO quota_month_mark(yyyy_mm, emailed_at) VALUES(?, ?) ON CONFLICT(yyyy_mm) DO UPDATE SET emailed_at = excluded.emailed_at"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        bindText(stmt, index: 1, yyyyMM)
        bindText(stmt, index: 2, iso(Date()))
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    public func isMonthEmailed(yyyyMM: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM quota_month_mark WHERE yyyy_mm = ?", -1, &stmt, nil) == SQLITE_OK else { return false }
        bindText(stmt, index: 1, yyyyMM)
        let found = sqlite3_step(stmt) == SQLITE_ROW
        sqlite3_finalize(stmt)
        return found
    }

    public func backfill(deepseek: [DeepSeekBalanceSnapshot], openAI: [OpenAIQuotaSnapshot]) {
        guard count() == 0 else { return }
        var dsByHour: [Date: Double] = [:]
        var oaByHour: [Date: Double] = [:]
        for snap in deepseek {
            dsByHour[flooredHour(snap.hour)] = snap.remainingRM / DeepSeekBalanceHistory.usdToMYR
        }
        for snap in openAI {
            oaByHour[flooredHour(snap.hour)] = snap.remainingPercent
        }
        let allHours = Set(dsByHour.keys).union(oaByHour.keys).sorted()
        for hour in allHours {
            let d = dsByHour[hour]
            let p = oaByHour[hour]
            if d == nil && p == nil { continue }
            let source: String
            if d != nil && p != nil {
                source = "both"
            } else if d != nil {
                source = "deepseek"
            } else {
                source = "openai"
            }
            record(hour: hour, deepseekUSD: d, openaiPercent: p, source: source)
        }
    }
}
