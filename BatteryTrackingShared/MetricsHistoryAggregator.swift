import Foundation

/// One metrics reading, in the neutral shape the shared layer understands.
/// The app fills it from `Metrics`, the helper from its own sampler.
struct MetricsHistorySample: Sendable {
    var date: Date
    var powerSys: Double
    var powerChip: Double
    var powerCpu: Double
    var powerGpu: Double
    var powerAne: Double
    /// Utilisation of the busiest cluster as a fraction in 0…1.
    var cpuUsage: Double
    var gpuUsage: Double
    var cpuFrequencyMHz: Double
    var gpuFrequencyMHz: Double
    /// Zero means the sensor gave nothing, and the reading is skipped.
    var temperatureCpu: Double
    var temperatureGpu: Double
}

/// One battery reading.
struct BatteryHistorySample: Sendable {
    var date: Date
    var currentCapacityMah: Int
    var maxCapacityMah: Int
    var isOnACPower: Bool
    var isCharging: Bool
    var isLowPowerMode: Bool

    var percent: Double {
        guard maxCapacityMah > 0 else { return 0 }
        return Double(currentCapacityMah) * 100 / Double(maxCapacityMah)
    }
}

/// Turns a stream of readings into minute buckets.
///
/// Every reading covers the span since the previous one, so the accumulated
/// integrals stay correct at any sampling rate. A span that crosses a minute
/// boundary is split between the two buckets. A span longer than `maximumGap`
/// counts as a gap: only `nominalGapSpan` of it is attributed, and the rest is
/// left uncovered so reports can show it as missing data.
final class MetricsHistoryAggregator {
    private var buckets: [Int: MetricsHistoryBucket] = [:]
    private var lastMetricsDate: Date?
    private var lastBattery: BatteryHistorySample?

    private let source: MetricsHistorySource
    private let maximumGap: TimeInterval
    private let nominalGapSpan: TimeInterval

    init(
        source: MetricsHistorySource,
        maximumGap: TimeInterval = 120,
        nominalGapSpan: TimeInterval = 5
    ) {
        self.source = source
        self.maximumGap = maximumGap
        self.nominalGapSpan = nominalGapSpan
    }

    var hasPendingBuckets: Bool { !buckets.isEmpty }

    func add(_ sample: MetricsHistorySample) {
        defer { lastMetricsDate = sample.date }
        guard let span = span(endingAt: sample.date, since: lastMetricsDate) else { return }

        let hasTemperature = sample.temperatureCpu > 0 || sample.temperatureGpu > 0

        distribute(span) { bucket, seconds in
            bucket.metricsSeconds += seconds

            bucket.energySysWs += sample.powerSys * seconds
            bucket.energyChipWs += sample.powerChip * seconds
            bucket.energyCpuWs += sample.powerCpu * seconds
            bucket.energyGpuWs += sample.powerGpu * seconds
            bucket.energyAneWs += sample.powerAne * seconds

            bucket.powerSysMax = max(bucket.powerSysMax, sample.powerSys)
            bucket.powerChipMax = max(bucket.powerChipMax, sample.powerChip)
            bucket.powerCpuMax = max(bucket.powerCpuMax, sample.powerCpu)
            bucket.powerGpuMax = max(bucket.powerGpuMax, sample.powerGpu)
            bucket.powerAneMax = max(bucket.powerAneMax, sample.powerAne)

            bucket.cpuUsageSeconds += sample.cpuUsage * seconds
            bucket.gpuUsageSeconds += sample.gpuUsage * seconds
            bucket.cpuUsageMax = max(bucket.cpuUsageMax, sample.cpuUsage)
            bucket.gpuUsageMax = max(bucket.gpuUsageMax, sample.gpuUsage)
            bucket.cpuFrequencySeconds += sample.cpuFrequencyMHz * seconds
            bucket.gpuFrequencySeconds += sample.gpuFrequencyMHz * seconds

            if hasTemperature {
                bucket.temperatureSeconds += seconds
                bucket.temperatureCpuSeconds += sample.temperatureCpu * seconds
                bucket.temperatureGpuSeconds += sample.temperatureGpu * seconds
                bucket.temperatureCpuMax = max(bucket.temperatureCpuMax, sample.temperatureCpu)
                bucket.temperatureGpuMax = max(bucket.temperatureGpuMax, sample.temperatureGpu)
            }
        }

        buckets[Self.bucketKey(for: sample.date), default: newBucket(at: sample.date)]
            .sampleCount += 1
    }

    func add(battery sample: BatteryHistorySample) {
        let previous = lastBattery
        defer { lastBattery = sample }
        guard let previous,
            let span = span(endingAt: sample.date, since: previous.date)
        else { return }

        // Capacity moves between the two readings, so spread the change over
        // the covered span rather than dropping it into one bucket.
        let capacityDelta = previous.currentCapacityMah - sample.currentCapacityMah
        let drainRate = span.seconds > 0 ? Double(max(0, capacityDelta)) / span.seconds : 0
        let chargeRate = span.seconds > 0 ? Double(max(0, -capacityDelta)) / span.seconds : 0

        distribute(span) { bucket, seconds in
            bucket.batterySeconds += seconds
            bucket.batteryPercentSeconds += previous.percent * seconds
            bucket.batteryDrainMah += drainRate * seconds
            bucket.batteryChargeMah += chargeRate * seconds
            if previous.isOnACPower {
                if previous.isCharging {
                    bucket.chargingSeconds += seconds
                }
            } else {
                bucket.onBatterySeconds += seconds
            }
            if previous.isLowPowerMode {
                bucket.lowPowerSeconds += seconds
            }
        }
    }

    /// Removes and returns every bucket that can no longer receive readings,
    /// that is every bucket before the one `now` falls into.
    func drainCompleted(now: Date = Date()) -> [MetricsHistoryBucket] {
        let currentKey = Self.bucketKey(for: now)
        let completedKeys = buckets.keys.filter { $0 < currentKey }
        return completedKeys
            .sorted()
            .compactMap { buckets.removeValue(forKey: $0) }
    }

    /// Removes and returns everything, including the bucket in progress. Use
    /// on shutdown so a partial minute is not lost.
    func drainAll() -> [MetricsHistoryBucket] {
        let drained = buckets.keys.sorted().compactMap { buckets.removeValue(forKey: $0) }
        buckets.removeAll()
        return drained
    }

    // MARK: - Spans

    private struct Span {
        var start: Date
        var end: Date
        var seconds: Double { max(0, end.timeIntervalSince(start)) }
    }

    /// The interval a reading covers, or nil when there is nothing to attribute.
    private func span(endingAt end: Date, since start: Date?) -> Span? {
        guard let start else { return nil }
        let elapsed = end.timeIntervalSince(start)
        guard elapsed > 0 else { return nil }
        guard elapsed <= maximumGap else {
            // Sleep, or a stopped sampler. Attribute only a nominal tail so the
            // gap stays visible as missing coverage.
            return Span(start: end.addingTimeInterval(-nominalGapSpan), end: end)
        }
        return Span(start: start, end: end)
    }

    /// Splits a span across the minute buckets it touches.
    private func distribute(_ span: Span, _ body: (inout MetricsHistoryBucket, Double) -> Void) {
        let resolution = Double(MetricsHistoryResolution.minute.seconds)
        var cursor = span.start

        while cursor < span.end {
            let key = Self.bucketKey(for: cursor)
            let bucketEnd = Date(timeIntervalSince1970: Double(key) + resolution)
            let sliceEnd = min(bucketEnd, span.end)
            let seconds = sliceEnd.timeIntervalSince(cursor)

            if seconds > 0 {
                var bucket = buckets[key] ?? newBucket(at: cursor)
                body(&bucket, seconds)
                buckets[key] = bucket
            }
            cursor = sliceEnd
        }
    }

    private func newBucket(at date: Date) -> MetricsHistoryBucket {
        MetricsHistoryBucket(
            bucketStart: Date(timeIntervalSince1970: Double(Self.bucketKey(for: date))),
            resolution: .minute,
            source: source
        )
    }

    private static func bucketKey(for date: Date) -> Int {
        let resolution = MetricsHistoryResolution.minute.seconds
        return Int((date.timeIntervalSince1970 / Double(resolution)).rounded(.down)) * resolution
    }
}
