import Foundation

/// Owns the history database for the app.
///
/// Every database call runs on one serial queue, which is what
/// `MetricsHistoryStore` requires. Marked `@unchecked Sendable` because that
/// confinement is enforced by the queue rather than by the type system.
final class MetricsHistoryService: @unchecked Sendable {
    static let shared = MetricsHistoryService()

    private let queue = DispatchQueue(label: "com.ftech.StillCoreLTR.history", qos: .utility)
    /// Queue-confined. Opened on first use so a broken database never blocks
    /// app launch.
    private var store: MetricsHistoryStore?
    private var openFailure: String?

    private init() {}

    /// Last database error, for the history section of the report window.
    private(set) nonisolated(unsafe) var lastErrorMessage: String = ""

    // MARK: - Writing

    /// Stores buckets without waiting for the write to finish.
    func submit(_ buckets: [MetricsHistoryBucket], heartbeat: Bool = false) {
        guard !buckets.isEmpty || heartbeat else { return }
        queue.async { [self] in
            write(buckets, heartbeat: heartbeat)
        }
    }

    /// Stores buckets and waits. Use on termination, where an async write would
    /// not survive the process.
    func flushSynchronously(_ buckets: [MetricsHistoryBucket]) {
        queue.sync { [self] in
            write(buckets, heartbeat: false)
        }
    }

    private func write(_ buckets: [MetricsHistoryBucket], heartbeat: Bool) {
        guard let store = openStore() else { return }
        do {
            for bucket in buckets {
                try store.upsert(bucket)
            }
            if heartbeat {
                try store.recordAppHeartbeat()
                try store.rollUpIfNeeded()
            }
            lastErrorMessage = ""
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Reading

    func report(for period: ReportPeriod, hardwareSummary: String) async throws -> Report {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    continuation.resume(
                        returning: try buildReport(period: period, hardwareSummary: hardwareSummary)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func buildReport(period: ReportPeriod, hardwareSummary: String) throws -> Report {
        guard let store = openStore() else {
            throw SQLiteError.open(
                path: MetricsHistoryConstants.defaultFileURL().path,
                message: openFailure ?? "unknown error")
        }

        // Hour rows are rebuilt from the minutes that are still around, so a
        // report opened right now includes the minutes recorded a moment ago.
        try store.rollUpIfNeeded(force: true)

        let calendar = Calendar.current
        let interval = period.interval(calendar: calendar)
        let hourBuckets = try store.buckets(
            resolution: .hour, from: interval.start, to: interval.end)

        // Minute rows drive the intraday curve of a day report. They overlap
        // the hour rows by construction, so they never feed the totals.
        var intraday: [MetricsHistoryBucket] = []
        if period.kind == .day {
            intraday = try store.buckets(
                resolution: .minute, from: interval.start, to: interval.end)
        }

        return Report.build(
            period: period,
            hourBuckets: hourBuckets,
            intraday: intraday,
            hardwareSummary: hardwareSummary,
            calendar: calendar
        )
    }

    /// Oldest and newest moment the database knows about.
    func availableRange() async -> DateInterval? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let store = openStore(), let earliest = try? store.earliestBucketStart()
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: DateInterval(start: earliest, end: max(earliest, Date())))
            }
        }
    }

    func storageByteCount() async -> Int64 {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: openStore()?.storageByteCount() ?? 0)
            }
        }
    }

    func clearHistory() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let store = openStore() else {
                        continuation.resume()
                        return
                    }
                    try store.deleteAll()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Lifetime

    private func openStore() -> MetricsHistoryStore? {
        if let store { return store }
        do {
            let store = try MetricsHistoryStore()
            self.store = store
            openFailure = nil
            return store
        } catch {
            openFailure = error.localizedDescription
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }
}
