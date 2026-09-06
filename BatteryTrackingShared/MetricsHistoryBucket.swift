import Foundation

/// Storage granularity. Minute rows are the source of truth inside the
/// retention window; hour rows are derived from them and kept long term.
enum MetricsHistoryResolution: Int, Sendable, CaseIterable {
    case minute = 60
    case hour = 3600

    var seconds: Int { rawValue }
}

/// Which process wrote the row. The app wins when both cover the same bucket,
/// because it samples far more often than the helper.
enum MetricsHistorySource: Int, Sendable {
    case app = 0
    case helper = 1
}

/// One time bucket of accumulated metrics.
///
/// Every averaged quantity is stored as a time integral (`Σ value · dt`)
/// together with the covered duration. Rolling minutes into hours, or hours
/// into a report period, is then a plain `SUM`, and the mean is recovered by
/// dividing by the matching duration. Peaks are stored directly and reduce
/// with `MAX`.
struct MetricsHistoryBucket: Sendable {
    var bucketStart: Date = .distantPast
    var resolution: MetricsHistoryResolution = .minute
    var source: MetricsHistorySource = .app
    /// Identifies the process that produced the row. Two processes of the same
    /// kind can run at once, and their readings must not be added together.
    var writer: String = ""

    /// Seconds covered by metrics samples. Weight for every metrics mean.
    var metricsSeconds: Double = 0
    var sampleCount: Double = 0

    /// Energy in watt-seconds, that is `Σ power · dt`.
    var energySysWs: Double = 0
    var energyChipWs: Double = 0
    var energyCpuWs: Double = 0
    var energyGpuWs: Double = 0
    var energyAneWs: Double = 0

    var powerSysMax: Double = 0
    var powerChipMax: Double = 0
    var powerCpuMax: Double = 0
    var powerGpuMax: Double = 0
    var powerAneMax: Double = 0

    /// `Σ fraction · dt`, where fraction is in 0…1.
    var cpuUsageSeconds: Double = 0
    var gpuUsageSeconds: Double = 0
    var cpuUsageMax: Double = 0
    var gpuUsageMax: Double = 0
    /// `Σ MHz · dt`.
    var cpuFrequencySeconds: Double = 0
    var gpuFrequencySeconds: Double = 0

    /// Seconds covered by valid temperature readings. Weight for the two sums
    /// below, which can be shorter than `metricsSeconds` on a cold start.
    var temperatureSeconds: Double = 0
    var temperatureCpuSeconds: Double = 0
    var temperatureGpuSeconds: Double = 0
    var temperatureCpuMax: Double = 0
    var temperatureGpuMax: Double = 0

    /// Seconds covered by battery readings. Weight for every battery mean.
    var batterySeconds: Double = 0
    var batteryPercentSeconds: Double = 0
    var batteryDrainMah: Double = 0
    var batteryChargeMah: Double = 0
    var onBatterySeconds: Double = 0
    var chargingSeconds: Double = 0
    var lowPowerSeconds: Double = 0

    var isEmpty: Bool {
        metricsSeconds <= 0 && batterySeconds <= 0
    }
}

extension MetricsHistoryBucket {
    enum Reducer {
        case sum
        case max
    }

    /// Column name, reducer and storage location for every numeric column.
    /// One table drives inserts, reads, roll-ups and period aggregation, so
    /// the four cannot drift apart.
    nonisolated(unsafe) static let numericColumns: [(
        name: String, reducer: Reducer, keyPath: WritableKeyPath<MetricsHistoryBucket, Double>
    )] = [
        ("metrics_s", .sum, \.metricsSeconds),
        ("sample_count", .sum, \.sampleCount),

        ("energy_sys_ws", .sum, \.energySysWs),
        ("energy_chip_ws", .sum, \.energyChipWs),
        ("energy_cpu_ws", .sum, \.energyCpuWs),
        ("energy_gpu_ws", .sum, \.energyGpuWs),
        ("energy_ane_ws", .sum, \.energyAneWs),

        ("power_sys_max", .max, \.powerSysMax),
        ("power_chip_max", .max, \.powerChipMax),
        ("power_cpu_max", .max, \.powerCpuMax),
        ("power_gpu_max", .max, \.powerGpuMax),
        ("power_ane_max", .max, \.powerAneMax),

        ("cpu_usage_s", .sum, \.cpuUsageSeconds),
        ("gpu_usage_s", .sum, \.gpuUsageSeconds),
        ("cpu_usage_max", .max, \.cpuUsageMax),
        ("gpu_usage_max", .max, \.gpuUsageMax),
        ("cpu_freq_mhz_s", .sum, \.cpuFrequencySeconds),
        ("gpu_freq_mhz_s", .sum, \.gpuFrequencySeconds),

        ("temp_s", .sum, \.temperatureSeconds),
        ("temp_cpu_s", .sum, \.temperatureCpuSeconds),
        ("temp_gpu_s", .sum, \.temperatureGpuSeconds),
        ("temp_cpu_max", .max, \.temperatureCpuMax),
        ("temp_gpu_max", .max, \.temperatureGpuMax),

        ("battery_s", .sum, \.batterySeconds),
        ("battery_percent_s", .sum, \.batteryPercentSeconds),
        ("battery_drain_mah", .sum, \.batteryDrainMah),
        ("battery_charge_mah", .sum, \.batteryChargeMah),
        ("on_battery_s", .sum, \.onBatterySeconds),
        ("charging_s", .sum, \.chargingSeconds),
        ("low_power_s", .sum, \.lowPowerSeconds),
    ]

    /// Adds another bucket of the same period into this one.
    mutating func merge(_ other: MetricsHistoryBucket) {
        for column in Self.numericColumns {
            switch column.reducer {
            case .sum:
                self[keyPath: column.keyPath] += other[keyPath: column.keyPath]
            case .max:
                self[keyPath: column.keyPath] = Swift.max(
                    self[keyPath: column.keyPath], other[keyPath: column.keyPath])
            }
        }
        source = MetricsHistorySource(rawValue: Swift.min(source.rawValue, other.source.rawValue))
            ?? source
    }

    static func merging(_ buckets: some Sequence<MetricsHistoryBucket>) -> MetricsHistoryBucket {
        var result = MetricsHistoryBucket()
        result.source = .helper
        for bucket in buckets {
            result.merge(bucket)
        }
        return result
    }
}

// MARK: - Derived report values

extension MetricsHistoryBucket {
    private static func mean(_ total: Double, over duration: Double) -> Double? {
        guard duration > 0 else { return nil }
        return total / duration
    }

    var energySysWh: Double { energySysWs / 3600 }
    var energyChipWh: Double { energyChipWs / 3600 }
    var energyCpuWh: Double { energyCpuWs / 3600 }
    var energyGpuWh: Double { energyGpuWs / 3600 }
    var energyAneWh: Double { energyAneWs / 3600 }

    /// Everything the system draws outside the SoC: display, ports, speakers.
    var energyOtherWh: Double { Swift.max(0, energySysWs - energyChipWs) / 3600 }
    /// Everything inside the SoC that is not CPU, GPU or ANE, mainly memory.
    var energyChipRestWh: Double {
        Swift.max(0, energyChipWs - energyCpuWs - energyGpuWs - energyAneWs) / 3600
    }

    var averagePowerSys: Double? { Self.mean(energySysWs, over: metricsSeconds) }
    var averagePowerChip: Double? { Self.mean(energyChipWs, over: metricsSeconds) }
    var averagePowerCpu: Double? { Self.mean(energyCpuWs, over: metricsSeconds) }
    var averagePowerGpu: Double? { Self.mean(energyGpuWs, over: metricsSeconds) }
    var averagePowerAne: Double? { Self.mean(energyAneWs, over: metricsSeconds) }

    /// Mean utilisation as a fraction in 0…1.
    var averageCpuUsage: Double? { Self.mean(cpuUsageSeconds, over: metricsSeconds) }
    var averageGpuUsage: Double? { Self.mean(gpuUsageSeconds, over: metricsSeconds) }
    var averageCpuFrequencyMHz: Double? { Self.mean(cpuFrequencySeconds, over: metricsSeconds) }
    var averageGpuFrequencyMHz: Double? { Self.mean(gpuFrequencySeconds, over: metricsSeconds) }

    var averageTemperatureCpu: Double? { Self.mean(temperatureCpuSeconds, over: temperatureSeconds) }
    var averageTemperatureGpu: Double? { Self.mean(temperatureGpuSeconds, over: temperatureSeconds) }

    var averageBatteryPercent: Double? { Self.mean(batteryPercentSeconds, over: batterySeconds) }
    /// Net battery change over the period, in mAh. Negative means discharge.
    var netBatteryMah: Double { batteryChargeMah - batteryDrainMah }
}
