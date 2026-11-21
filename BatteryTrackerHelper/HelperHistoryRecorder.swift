import Foundation
import MacmonSwift

/// Records metrics history while the app is closed.
///
/// The app samples far more often and wins every bucket it covers, so this
/// recorder only steps in when the app heartbeat goes stale. It samples once
/// every `metricsInterval` to keep the helper's own draw negligible, and it
/// releases the sampler as soon as the app comes back.
final class HelperHistoryRecorder {
    /// How often metrics are sampled while the helper is the only recorder.
    private static let metricsInterval: TimeInterval = 30
    /// How often the roll-up is attempted. The store enforces its own spacing.
    private static let maintenanceInterval: TimeInterval = 600

    private var store: MetricsHistoryStore?
    private var storeFailed = false
    private var sampler: Sampler?
    private var aggregator: MetricsHistoryAggregator
    private var lastMetricsSample: Date = .distantPast
    private var lastMaintenance: Date = .distantPast

    init() {
        // Spans match the sampling interval, and anything much longer than a
        // couple of missed cycles counts as sleep rather than as coverage.
        aggregator = MetricsHistoryAggregator(
            source: .helper,
            maximumGap: Self.metricsInterval * 3,
            nominalGapSpan: Self.metricsInterval)
    }

    /// Called once per helper poll cycle.
    func record(batteryStatus: BatteryStatus?, now: Date) {
        guard let store = openStore() else { return }

        if let batteryStatus {
            aggregator.add(
                battery: BatteryHistorySample(
                    date: now,
                    currentCapacityMah: batteryStatus.currentCapacityMah,
                    maxCapacityMah: batteryStatus.maxCapacityMah,
                    isOnACPower: batteryStatus.isOnACPower,
                    isCharging: batteryStatus.isCharging,
                    isLowPowerMode: batteryStatus.powerSaveMode))
        }

        if store.isAppRecording(now: now) {
            releaseSampler()
        } else if now.timeIntervalSince(lastMetricsSample) >= Self.metricsInterval {
            lastMetricsSample = now
            sampleMetrics(now: now)
        }

        flush(to: store, now: now)
    }

    // MARK: - Sampling

    private func sampleMetrics(now: Date) {
        guard let sampler = openSampler() else { return }
        guard let metrics = try? sampler.metrics() else {
            // A failing sampler is not worth keeping around; the next cycle
            // makes a fresh one.
            releaseSampler()
            return
        }
        aggregator.add(Self.historySample(from: metrics, date: now))
    }

    private func openSampler() -> Sampler? {
        if let sampler { return sampler }
        sampler = try? Sampler()
        // A fresh sampler has no previous reading to compare against, so the
        // first span starts from the next cycle.
        return sampler
    }

    private func releaseSampler() {
        guard sampler != nil else { return }
        sampler?.close()
        sampler = nil
    }

    // MARK: - Writing

    /// Writes everything accumulated so far, including the minute in progress.
    ///
    /// Buckets from the same source accumulate on conflict, so writing a
    /// partial minute now and the rest of it later adds up correctly. That way
    /// the helper loses nothing if launchd stops it between cycles.
    private func flush(to store: MetricsHistoryStore, now: Date) {
        for bucket in aggregator.drainAll() {
            try? store.upsert(bucket)
        }

        guard now.timeIntervalSince(lastMaintenance) >= Self.maintenanceInterval else { return }
        lastMaintenance = now
        _ = try? store.rollUpIfNeeded(now: now)
    }

    private func openStore() -> MetricsHistoryStore? {
        if let store { return store }
        guard !storeFailed else { return nil }
        do {
            store = try MetricsHistoryStore()
        } catch {
            // One failure is enough: a broken database must not turn the helper
            // into a process that retries on every cycle forever.
            storeFailed = true
        }
        return store
    }

    // MARK: - Conversion

    /// Same conversion as the app's `MetricsHistoryRecorder`, so both sources
    /// write comparable buckets.
    private static func historySample(from metrics: Metrics, date: Date) -> MetricsHistorySample {
        MetricsHistorySample(
            date: date,
            powerSys: Double(metrics.sysPower),
            powerChip: Double(metrics.chipPower),
            powerCpu: Double(metrics.cpuPower),
            powerGpu: Double(metrics.gpuPower),
            powerAne: Double(metrics.anePower),
            cpuUsage: Double(metrics.cpuActiveRatio),
            gpuUsage: Double(metrics.gpuActiveRatio),
            cpuFrequencyMHz: cpuFrequency(metrics.cpuTiers),
            gpuFrequencyMHz: Double(metrics.gpuFreqMHz),
            temperatureCpu: Double(metrics.temp.cpuTempAvg),
            temperatureGpu: Double(metrics.temp.gpuTempAvg))
    }

    private static func cpuFrequency(_ tiers: [CpuTierMetrics]) -> Double {
        let totalWeight = tiers.reduce(0) { $0 + max(1, $1.cores.count) }
        if totalWeight == 0 { return 0 }
        let weighted = tiers.reduce(0.0) { $0 + Double($1.freqMHz) * Double(max(1, $1.cores.count)) }
        return weighted / Double(totalWeight)
    }
}
