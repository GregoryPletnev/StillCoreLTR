import Foundation

enum MetricsHistoryConstants {
    static let databaseFilename = "metrics-history.sqlite"
    /// How long minute rows stay before they are rolled into hours and deleted.
    static let minuteRetention: TimeInterval = 14 * 24 * 3600
    /// How long hour rows stay. Reports never look further back than this.
    static let hourRetention: TimeInterval = 5 * 365 * 24 * 3600
    /// The helper only samples metrics when the app heartbeat is older than this.
    static let appHeartbeatTimeout: TimeInterval = 90
    /// Shortest gap between two roll-up passes, whichever process runs them.
    static let rollupInterval: TimeInterval = 600

    static func defaultFileURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupportURL
            .appendingPathComponent(BatteryTrackerConstants.stateDirectoryName, isDirectory: true)
            .appendingPathComponent(databaseFilename, isDirectory: false)
    }
}

/// Reads and writes the metrics history database.
///
/// Not thread safe: keep one instance per queue. Two processes may hold their
/// own instance at the same time; WAL mode and the busy timeout make that safe.
final class MetricsHistoryStore {
    private enum MetaKey {
        static let appHeartbeat = "app_heartbeat_at"
        static let lastRollup = "last_rollup_at"
    }

    private static let schemaVersion = 2
    private static let keyColumns = ["resolution", "bucket_start", "source", "writer"]

    /// Identity of this process as a writer, stable for its lifetime.
    static let processWriterID = UUID().uuidString

    private let database: SQLiteDatabase
    let fileURL: URL

    init(fileURL: URL = MetricsHistoryConstants.defaultFileURL()) throws {
        self.fileURL = fileURL
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: fileURL.path)
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        let version = try database.userVersion()
        guard version < Self.schemaVersion else { return }

        if version == 1 {
            try database.execute(
                "ALTER TABLE buckets ADD COLUMN writer TEXT NOT NULL DEFAULT ''")
            try database.setUserVersion(Self.schemaVersion)
            return
        }

        let columnDefinitions = MetricsHistoryBucket.numericColumns
            .map { "    \($0.name) REAL NOT NULL DEFAULT 0" }
            .joined(separator: ",\n")

        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS buckets (
                resolution INTEGER NOT NULL,
                bucket_start INTEGER NOT NULL,
                source INTEGER NOT NULL,
                writer TEXT NOT NULL DEFAULT '',
            \(columnDefinitions),
                PRIMARY KEY (resolution, bucket_start)
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )
        try database.setUserVersion(Self.schemaVersion)
    }

    // MARK: - Writing

    /// Stores one bucket.
    ///
    /// Conflicts on the same bucket resolve in three steps:
    ///
    /// - The app beats the helper, never the other way round, because it
    ///   samples far more often.
    /// - Within one source, two writes from the same process accumulate, so a
    ///   partial bucket flushed early is completed rather than replaced.
    /// - Within one source, a write from a different process replaces the row
    ///   only when it covers more time. Two app instances running at once would
    ///   otherwise add up to more coverage than the bucket can hold.
    func upsert(_ bucket: MetricsHistoryBucket) throws {
        guard !bucket.isEmpty else { return }

        var parameters: [SQLiteValue] = [
            SQLiteValue(bucket.resolution.rawValue),
            SQLiteValue(Int(bucket.bucketStart.timeIntervalSince1970.rounded())),
            SQLiteValue(bucket.source.rawValue),
            SQLiteValue(bucket.writer.isEmpty ? Self.processWriterID : bucket.writer),
        ]
        parameters += MetricsHistoryBucket.numericColumns.map {
            SQLiteValue(bucket[keyPath: $0.keyPath])
        }

        try database.run(Self.upsertSQL, parameters)
    }

    private static let upsertSQL: String = {
        let names = keyColumns + MetricsHistoryBucket.numericColumns.map(\.name)
        let placeholders = Array(repeating: "?", count: names.count).joined(separator: ", ")

        // True when the incoming row should replace the stored one outright.
        let replaces = """
            (excluded.source < buckets.source
                OR (excluded.writer <> buckets.writer
                    AND excluded.metrics_s + excluded.battery_s
                        > buckets.metrics_s + buckets.battery_s))
            """

        let assignments = MetricsHistoryBucket.numericColumns.map { column in
            let merged = switch column.reducer {
            case .sum: "buckets.\(column.name) + excluded.\(column.name)"
            case .max: "MAX(buckets.\(column.name), excluded.\(column.name))"
            }
            return """
                \(column.name) = CASE
                        WHEN \(replaces) THEN excluded.\(column.name)
                        WHEN excluded.writer = buckets.writer THEN \(merged)
                        ELSE buckets.\(column.name) END
                """
        }

        return """
            INSERT INTO buckets (\(names.joined(separator: ", ")))
            VALUES (\(placeholders))
            ON CONFLICT(resolution, bucket_start) DO UPDATE SET
                source = MIN(buckets.source, excluded.source),
                writer = CASE WHEN \(replaces) THEN excluded.writer ELSE buckets.writer END,
                \(assignments.joined(separator: ",\n    "))
            WHERE excluded.source <= buckets.source
            """
    }()

    func recordAppHeartbeat(at date: Date = Date()) throws {
        try setMeta(MetaKey.appHeartbeat, date.timeIntervalSince1970)
    }

    /// True when the app has written a heartbeat recently enough that the
    /// helper should stay out of metrics sampling.
    func isAppRecording(now: Date = Date()) -> Bool {
        guard let heartbeat = try? meta(MetaKey.appHeartbeat) else { return false }
        return now.timeIntervalSince1970 - heartbeat < MetricsHistoryConstants.appHeartbeatTimeout
    }

    // MARK: - Roll-up and retention

    /// Rebuilds hour rows from the minute rows that still exist, then drops
    /// minute rows past their retention. Idempotent, so either process may run
    /// it. Does nothing if another process ran it recently.
    @discardableResult
    func rollUpIfNeeded(now: Date = Date(), force: Bool = false) throws -> Bool {
        if !force, let lastRollup = try meta(MetaKey.lastRollup) {
            let elapsed = now.timeIntervalSince1970 - lastRollup
            guard elapsed >= MetricsHistoryConstants.rollupInterval || elapsed < 0 else {
                return false
            }
        }

        try database.transaction {
            try database.execute(Self.rollUpSQL)
            try database.run(
                "DELETE FROM buckets WHERE resolution = ? AND bucket_start < ?",
                [
                    SQLiteValue(MetricsHistoryResolution.minute.rawValue),
                    SQLiteValue(
                        Int(
                            (now.timeIntervalSince1970 - MetricsHistoryConstants.minuteRetention)
                                .rounded())),
                ])
            try database.run(
                "DELETE FROM buckets WHERE resolution = ? AND bucket_start < ?",
                [
                    SQLiteValue(MetricsHistoryResolution.hour.rawValue),
                    SQLiteValue(
                        Int(
                            (now.timeIntervalSince1970 - MetricsHistoryConstants.hourRetention)
                                .rounded())),
                ])
        }
        try setMeta(MetaKey.lastRollup, now.timeIntervalSince1970)
        return true
    }

    private static let rollUpSQL: String = {
        let hour = MetricsHistoryResolution.hour.rawValue
        let minute = MetricsHistoryResolution.minute.rawValue
        let names = MetricsHistoryBucket.numericColumns.map(\.name)
        let reductions = MetricsHistoryBucket.numericColumns.map { column in
            switch column.reducer {
            case .sum: "SUM(\(column.name))"
            case .max: "MAX(\(column.name))"
            }
        }
        let assignments = (["source", "writer"] + names)
            .map { "\($0) = excluded.\($0)" }
            .joined(separator: ", ")

        // An hour is always recomputed in full from the minutes that remain,
        // so replacing the stored row is correct.
        return """
            INSERT INTO buckets (resolution, bucket_start, source, writer, \(names.joined(separator: ", ")))
            SELECT \(hour), bucket_start / \(hour) * \(hour), MIN(source), 'rollup',
                   \(reductions.joined(separator: ", "))
            FROM buckets
            WHERE resolution = \(minute)
            GROUP BY bucket_start / \(hour)
            ON CONFLICT(resolution, bucket_start) DO UPDATE SET \(assignments)
            """
    }()

    // MARK: - Reading

    /// Returns every stored bucket of one resolution that starts inside the
    /// half-open interval, ordered by time.
    func buckets(
        resolution: MetricsHistoryResolution,
        from startDate: Date,
        to endDate: Date
    ) throws -> [MetricsHistoryBucket] {
        let names = Self.keyColumns + MetricsHistoryBucket.numericColumns.map(\.name)
        let sql = """
            SELECT \(names.joined(separator: ", "))
            FROM buckets
            WHERE resolution = ? AND bucket_start >= ? AND bucket_start < ?
            ORDER BY bucket_start
            """
        return try database.query(
            sql,
            [
                SQLiteValue(resolution.rawValue),
                SQLiteValue(Int(startDate.timeIntervalSince1970.rounded(.down))),
                SQLiteValue(Int(endDate.timeIntervalSince1970.rounded(.up))),
            ]
        ) { row in
            var bucket = MetricsHistoryBucket()
            bucket.resolution =
                MetricsHistoryResolution(rawValue: Int(row.int(at: 0))) ?? resolution
            bucket.bucketStart = Date(timeIntervalSince1970: Double(row.int(at: 1)))
            bucket.source = MetricsHistorySource(rawValue: Int(row.int(at: 2))) ?? .app
            bucket.writer = row.text(at: 3) ?? ""
            for (offset, column) in MetricsHistoryBucket.numericColumns.enumerated() {
                bucket[keyPath: column.keyPath] = row.double(at: Int32(offset + 4))
            }
            return bucket
        }
    }

    /// Start of the oldest stored bucket, or nil when the database is empty.
    func earliestBucketStart() throws -> Date? {
        let value = try database.queryFirst(
            "SELECT MIN(bucket_start) FROM buckets"
        ) { row in row.isNull(at: 0) ? nil : Double(row.int(at: 0)) }
        return value.flatMap { $0 }.map(Date.init(timeIntervalSince1970:))
    }

    func storageByteCount() -> Int64 {
        let values = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (values?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func deleteAll() throws {
        try database.execute("DELETE FROM buckets")
        try database.execute("VACUUM")
    }

    // MARK: - Meta

    private func meta(_ key: String) throws -> Double? {
        let value = try database.queryFirst(
            "SELECT value FROM meta WHERE key = ?", [SQLiteValue(key)]
        ) { row in row.text(at: 0) }
        return value.flatMap { $0 }.flatMap(Double.init)
    }

    private func setMeta(_ key: String, _ value: Double) throws {
        try database.run(
            """
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            [SQLiteValue(key), SQLiteValue(String(value))])
    }
}
