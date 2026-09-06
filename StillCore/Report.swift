import Foundation

/// One table row and chart bar of a report.
struct ReportRow: Identifiable, Sendable {
    let id: Int
    let range: DateInterval
    let label: String
    let axisLabel: String
    let bucket: MetricsHistoryBucket

    /// Share of the row that metrics actually cover, in 0…1. Anything below 1
    /// means the Mac was off, asleep, or nothing was recording.
    var coverage: Double {
        guard range.duration > 0 else { return 0 }
        return min(1, bucket.metricsSeconds / range.duration)
    }

    var hasData: Bool { !bucket.isEmpty }

    /// Unique x value for the charts. Labels repeat inside a period — two
    /// months can both shorten to "J" — so the index is what identifies a row.
    var chartKey: String { String(format: "%04d", id) }
}

/// Everything one report shows, ready for the table, the charts and the printer.
struct Report: Sendable {
    let period: ReportPeriod
    let periodInterval: DateInterval
    let generatedAt: Date
    let rows: [ReportRow]
    let total: MetricsHistoryBucket
    let hardwareSummary: String
    /// Minute rows for a day report, used only for the intraday power curve.
    /// Never mixed into the totals, which always come from hour rows.
    let intraday: [MetricsHistoryBucket]

    var totalCoverage: Double {
        guard periodInterval.duration > 0 else { return 0 }
        return min(1, total.metricsSeconds / periodInterval.duration)
    }

    var hasData: Bool { !total.isEmpty }

    /// Seconds the period covers up to now, so the current day or month is not
    /// judged against a span that has not happened yet.
    func elapsedSeconds(now: Date = Date()) -> Double {
        min(periodInterval.duration, max(0, now.timeIntervalSince(periodInterval.start)))
    }

    static func build(
        period: ReportPeriod,
        hourBuckets: [MetricsHistoryBucket],
        intraday: [MetricsHistoryBucket] = [],
        hardwareSummary: String,
        generatedAt: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> Report {
        let plan = ReportBucketPlan(period: period, calendar: calendar)
        var grouped = [MetricsHistoryBucket](
            repeating: MetricsHistoryBucket(), count: plan.starts.count)

        for bucket in hourBuckets {
            guard let index = plan.index(for: bucket.bucketStart) else { continue }
            grouped[index].merge(bucket)
        }

        let rows = grouped.enumerated().map { index, bucket in
            ReportRow(
                id: index,
                range: plan.range(at: index),
                label: plan.label(at: index, locale: locale),
                axisLabel: plan.axisLabel(at: index, locale: locale),
                bucket: bucket
            )
        }

        return Report(
            period: period,
            periodInterval: plan.interval,
            generatedAt: generatedAt,
            rows: rows,
            total: MetricsHistoryBucket.merging(grouped),
            hardwareSummary: hardwareSummary,
            intraday: intraday
        )
    }
}

// MARK: - Summary figures

extension Report {
    struct Highlight: Identifiable, Sendable {
        let id: String
        let title: String
        let value: String
        let detail: String
    }

    /// The figures printed across the top of the report.
    func highlights(now: Date = Date()) -> [Highlight] {
        let elapsed = elapsedSeconds(now: now)
        let energy = total.energySysWh

        var highlights: [Highlight] = [
            Highlight(
                id: "energy",
                title: "System energy",
                value: ReportFormat.energy(energy),
                detail: projectionDetail(energy: energy, elapsed: elapsed)
            ),
            Highlight(
                id: "average",
                title: "Average power",
                value: ReportFormat.power(total.averagePowerSys),
                detail: "Peak \(ReportFormat.power(total.powerSysMax > 0 ? total.powerSysMax : nil))"
            ),
            Highlight(
                id: "chip",
                title: "Chip energy",
                value: ReportFormat.energy(total.energyChipWh),
                detail: energy > 0
                    ? "\(ReportFormat.percent(total.energyChipWh / energy)) of system"
                    : "No data"
            ),
        ]

        if total.batterySeconds > 0 {
            let onBatteryShare = total.onBatterySeconds / total.batterySeconds
            highlights.append(
                Highlight(
                    id: "battery",
                    title: "Battery drained",
                    value: ReportFormat.capacity(total.batteryDrainMah),
                    detail: "\(ReportFormat.percent(onBatteryShare)) of time unplugged"
                ))
        }

        highlights.append(
            Highlight(
                id: "coverage",
                title: "Coverage",
                value: ReportFormat.percent(coverageAgainstElapsed(now: now)),
                detail: ReportFormat.duration(total.metricsSeconds) + " recorded"
            ))

        return highlights
    }

    /// Coverage measured against the part of the period that has already
    /// happened, so a report opened at noon does not read as half empty.
    func coverageAgainstElapsed(now: Date = Date()) -> Double {
        let elapsed = elapsedSeconds(now: now)
        guard elapsed > 0 else { return 0 }
        return min(1, total.metricsSeconds / elapsed)
    }

    /// Extrapolates a period still in progress to its full length.
    private func projectionDetail(energy: Double, elapsed: Double) -> String {
        guard period.isCurrent(), elapsed > 0, total.metricsSeconds > 0 else {
            return ReportFormat.duration(total.metricsSeconds) + " recorded"
        }
        let projected = energy / total.metricsSeconds * periodInterval.duration
        return "≈\(ReportFormat.energy(projected)) at this rate"
    }
}

// MARK: - CSV

extension Report {
    /// One row per table row, with the same figures the table shows.
    func csv(locale: Locale = FormatLocale.posix) -> String {
        let header = [
            "start", "end", "label",
            "energy_sys_wh", "energy_chip_wh", "energy_cpu_wh", "energy_gpu_wh", "energy_ane_wh",
            "avg_power_sys_w", "peak_power_sys_w",
            "avg_cpu_usage", "avg_gpu_usage", "avg_cpu_freq_mhz", "avg_gpu_freq_mhz",
            "avg_temp_cpu_c", "avg_temp_gpu_c", "max_temp_cpu_c", "max_temp_gpu_c",
            "battery_drain_mah", "battery_charge_mah", "on_battery_s", "charging_s",
            "covered_s", "coverage",
        ]

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime]

        func number(_ value: Double?, _ decimals: Int) -> String {
            guard let value else { return "" }
            return String(format: "%.\(decimals)f", locale: locale, value)
        }

        var lines = [header.joined(separator: ",")]
        for row in rows {
            let bucket = row.bucket
            let fields: [String] = [
                timestampFormatter.string(from: row.range.start),
                timestampFormatter.string(from: row.range.end),
                "\"\(row.label.replacingOccurrences(of: "\"", with: "\"\""))\"",
                number(bucket.energySysWh, 4), number(bucket.energyChipWh, 4),
                number(bucket.energyCpuWh, 4), number(bucket.energyGpuWh, 4),
                number(bucket.energyAneWh, 4),
                number(bucket.averagePowerSys, 3), number(bucket.powerSysMax, 3),
                number(bucket.averageCpuUsage, 4), number(bucket.averageGpuUsage, 4),
                number(bucket.averageCpuFrequencyMHz, 1),
                number(bucket.averageGpuFrequencyMHz, 1),
                number(bucket.averageTemperatureCpu, 1), number(bucket.averageTemperatureGpu, 1),
                number(bucket.temperatureCpuMax, 1), number(bucket.temperatureGpuMax, 1),
                number(bucket.batteryDrainMah, 1), number(bucket.batteryChargeMah, 1),
                number(bucket.onBatterySeconds, 0), number(bucket.chargingSeconds, 0),
                number(bucket.metricsSeconds, 0), number(row.coverage, 4),
            ]
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// File name stem for exports, safe on every file system.
    func exportName() -> String {
        let formatter = DateFormatter()
        formatter.locale = FormatLocale.posix
        switch period.kind {
        case .day: formatter.dateFormat = "yyyy-MM-dd"
        case .month: formatter.dateFormat = "yyyy-MM"
        case .quarter: formatter.dateFormat = "yyyy-'Q'Q"
        case .year: formatter.dateFormat = "yyyy"
        }
        return "StillCore-\(period.kind.rawValue)-\(formatter.string(from: periodInterval.start))"
    }
}

// MARK: - Shared formatting

enum ReportFormat {
    static func energy(_ wattHours: Double?) -> String {
        guard let wattHours, wattHours.isFinite else { return "—" }
        if wattHours >= 1000 {
            return String(format: "%.2f kWh", locale: FormatLocale.posix, wattHours / 1000)
        }
        if wattHours >= 10 {
            return String(format: "%.1f Wh", locale: FormatLocale.posix, wattHours)
        }
        return String(format: "%.2f Wh", locale: FormatLocale.posix, wattHours)
    }

    static func power(_ watts: Double?) -> String {
        guard let watts, watts.isFinite else { return "—" }
        return String(format: "%.2f W", locale: FormatLocale.posix, watts)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return String(format: "%.0f%%", locale: FormatLocale.posix, fraction * 100)
    }

    static func usage(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "—" }
        return String(format: "%.1f%%", locale: FormatLocale.posix, fraction * 100)
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite, celsius > 0 else { return "—" }
        return String(format: "%.0f °C", locale: FormatLocale.posix, celsius)
    }

    static func frequency(_ megahertz: Double?) -> String {
        guard let megahertz, megahertz.isFinite, megahertz > 0 else { return "—" }
        return String(format: "%.2f GHz", locale: FormatLocale.posix, megahertz / 1000)
    }

    static func capacity(_ milliampHours: Double?) -> String {
        guard let milliampHours, milliampHours.isFinite, milliampHours > 0 else { return "—" }
        // A year of discharge runs into six digits of mAh, which nobody reads.
        if milliampHours >= 10_000 {
            return String(format: "%.1f Ah", locale: FormatLocale.posix, milliampHours / 1000)
        }
        return String(format: "%.0f mAh", locale: FormatLocale.posix, milliampHours)
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        guard total >= 60 else { return "\(total)s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
