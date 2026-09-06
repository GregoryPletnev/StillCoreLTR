import AppKit
import Charts
import SwiftUI

/// Colours for the report, taken from the live charts so the same component
/// keeps the same hue everywhere in the app.
enum ReportPalette {
    static let cpu = Color(nsColor: MetricsChartPalette.cpu)
    static let gpu = Color(nsColor: MetricsChartPalette.gpu)
    static let ane = Color(nsColor: MetricsChartPalette.ane)
    static let chip = Color(nsColor: MetricsChartPalette.package)
    static let system = Color(nsColor: MetricsChartPalette.board)
}

/// Parts the system energy is split into. Fixed order: a component always
/// takes the same slot and the same colour, whatever the report shows.
enum ReportEnergyComponent: String, CaseIterable {
    case cpu = "CPU"
    case gpu = "GPU"
    case ane = "ANE"
    case chipRest = "Chip, rest"
    case systemRest = "Display & I/O"

    var color: Color {
        switch self {
        case .cpu: return ReportPalette.cpu
        case .gpu: return ReportPalette.gpu
        case .ane: return ReportPalette.ane
        case .chipRest: return ReportPalette.chip
        case .systemRest: return ReportPalette.system
        }
    }

    func energyWh(in bucket: MetricsHistoryBucket) -> Double {
        switch self {
        case .cpu: return bucket.energyCpuWh
        case .gpu: return bucket.energyGpuWh
        case .ane: return bucket.energyAneWh
        case .chipRest: return bucket.energyChipRestWh
        case .systemRest: return bucket.energyOtherWh
        }
    }
}

// MARK: - Categorical axis

/// The x axis shared by every period chart.
///
/// Charts plot on the row index rather than on the row label, because labels
/// repeat across a period while indices never do. The full period is always in
/// the domain, so a period with one recorded hour shows one narrow bar in the
/// right place instead of one bar stretched across the plot.
struct ReportCategoryAxis {
    let domain: [String]
    let shownValues: [String]
    private let labels: [String: String]

    init(rows: [ReportRow], maximumLabels: Int = 12) {
        domain = rows.map(\.chartKey)
        labels = Dictionary(uniqueKeysWithValues: rows.map { ($0.chartKey, $0.axisLabel) })

        if rows.count <= maximumLabels {
            shownValues = domain
        } else {
            let step = Int((Double(rows.count) / Double(maximumLabels)).rounded(.up))
            shownValues = rows.enumerated()
                .filter { $0.offset % step == 0 }
                .map { $0.element.chartKey }
        }
    }

    func label(for value: String) -> String { labels[value] ?? "" }
}

extension View {
    /// Applies the shared categorical scale and axis labels to a report chart.
    func reportCategoryAxis(_ axis: ReportCategoryAxis) -> some View {
        chartXScale(domain: axis.domain)
            .chartXAxis {
                AxisMarks(values: axis.shownValues) { value in
                    if let key = value.as(String.self) {
                        AxisValueLabel(axis.label(for: key))
                    }
                }
            }
    }
}

// MARK: - Chart frame

/// Title, unit and surface shared by every report chart.
struct ReportChartCard<Content: View>: View {
    let title: String
    let unit: String
    var note: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(12)
        .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Placeholder for a period with nothing recorded, so an empty chart never
/// reads as a period of zero consumption.
private struct ReportChartEmptyState: View {
    var body: some View {
        Text("No data recorded for this period")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Energy by component

struct ReportEnergyChart: View {
    let rows: [ReportRow]
    var height: CGFloat = 200

    private var recorded: [ReportRow] { rows.filter(\.hasData) }

    var body: some View {
        ReportChartCard(title: "Energy by component", unit: "Wh") {
            if recorded.isEmpty {
                ReportChartEmptyState()
            } else {
                Chart {
                    ForEach(recorded) { row in
                        ForEach(ReportEnergyComponent.allCases, id: \.rawValue) { component in
                            let value = component.energyWh(in: row.bucket)
                            if value > 0 {
                                BarMark(
                                    x: .value("Period", row.chartKey),
                                    y: .value("Energy", value)
                                )
                                .foregroundStyle(by: .value("Component", component.rawValue))
                                // Rounded ends separate the stacked segments,
                                // which the palette needs in dark mode.
                                .cornerRadius(2)
                            }
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: ReportEnergyComponent.allCases.map(\.rawValue),
                    range: ReportEnergyComponent.allCases.map(\.color)
                )
                .chartLegend(position: .bottom, spacing: 8)
                .reportCategoryAxis(ReportCategoryAxis(rows: rows))
                .frame(height: height)
            }
        }
    }
}

// MARK: - Average and peak power

struct ReportPowerChart: View {
    let rows: [ReportRow]
    var height: CGFloat = 160

    private var recorded: [ReportRow] {
        rows.filter { $0.hasData && $0.bucket.averagePowerSys != nil }
    }

    var body: some View {
        ReportChartCard(title: "System power", unit: "W", note: "average bar, peak marker") {
            if recorded.isEmpty {
                ReportChartEmptyState()
            } else {
                Chart {
                    ForEach(recorded) { row in
                        BarMark(
                            x: .value("Period", row.chartKey),
                            y: .value("Average", row.bucket.averagePowerSys ?? 0)
                        )
                        .foregroundStyle(ReportPalette.system)
                        .cornerRadius(2)

                        PointMark(
                            x: .value("Period", row.chartKey),
                            y: .value("Peak", row.bucket.powerSysMax)
                        )
                        .symbolSize(30)
                        .foregroundStyle(ReportPalette.gpu)
                    }
                }
                .reportCategoryAxis(ReportCategoryAxis(rows: rows))
                .frame(height: height)

                ReportChartLegend(items: [
                    (ReportPalette.system, "Average"),
                    (ReportPalette.gpu, "Peak"),
                ])
            }
        }
    }
}

// MARK: - Battery

struct ReportBatteryChart: View {
    let rows: [ReportRow]
    var height: CGFloat = 140

    private var recorded: [ReportRow] {
        rows.filter { $0.bucket.batteryDrainMah > 0 }
    }

    var body: some View {
        ReportChartCard(title: "Battery drained", unit: "mAh") {
            if recorded.isEmpty {
                ReportChartEmptyState()
            } else {
                // One series, so the title carries the identity and no legend
                // box is needed.
                Chart {
                    ForEach(recorded) { row in
                        BarMark(
                            x: .value("Period", row.chartKey),
                            y: .value("Drained", row.bucket.batteryDrainMah)
                        )
                        .foregroundStyle(ReportPalette.ane)
                        .cornerRadius(2)
                    }
                }
                .reportCategoryAxis(ReportCategoryAxis(rows: rows))
                .frame(height: height)
            }
        }
    }
}

// MARK: - Two-series line charts

/// Utilisation and temperature share a shape: two series over the period, with
/// the line broken wherever nothing was recorded.
///
/// Markers are always drawn. Without them an isolated recorded period would be
/// a line segment of zero length, that is nothing at all.
private struct ReportTwoSeriesLineChart: View {
    let rows: [ReportRow]
    let title: String
    let unit: String
    let height: CGFloat
    let firstName: String
    let secondName: String
    let firstValue: (MetricsHistoryBucket) -> Double?
    let secondValue: (MetricsHistoryBucket) -> Double?

    private var runs: [[ReportRow]] {
        var runs: [[ReportRow]] = []
        var current: [ReportRow] = []
        for row in rows {
            if firstValue(row.bucket) != nil {
                current.append(row)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    var body: some View {
        ReportChartCard(title: title, unit: unit) {
            let runs = runs
            if runs.isEmpty {
                ReportChartEmptyState()
            } else {
                Chart {
                    ForEach(Array(runs.enumerated()), id: \.offset) { runIndex, run in
                        ForEach(run) { row in
                            LineMark(
                                x: .value("Period", row.chartKey),
                                y: .value(unit, firstValue(row.bucket) ?? 0),
                                series: .value("Run", "first-\(runIndex)")
                            )
                            .foregroundStyle(by: .value("Unit", firstName))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .symbol(Circle())
                            .symbolSize(24)

                            LineMark(
                                x: .value("Period", row.chartKey),
                                y: .value(unit, secondValue(row.bucket) ?? 0),
                                series: .value("Run", "second-\(runIndex)")
                            )
                            .foregroundStyle(by: .value("Unit", secondName))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .symbol(Circle())
                            .symbolSize(24)
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: [firstName, secondName],
                    range: [ReportPalette.cpu, ReportPalette.gpu]
                )
                .chartLegend(position: .bottom, spacing: 8)
                .reportCategoryAxis(ReportCategoryAxis(rows: rows))
                .frame(height: height)
            }
        }
    }
}

struct ReportUtilisationChart: View {
    let rows: [ReportRow]
    var height: CGFloat = 140

    var body: some View {
        ReportTwoSeriesLineChart(
            rows: rows,
            title: "Average utilisation",
            unit: "%",
            height: height,
            firstName: "CPU",
            secondName: "GPU",
            firstValue: { $0.averageCpuUsage.map { $0 * 100 } },
            secondValue: { $0.averageGpuUsage.map { $0 * 100 } }
        )
    }
}

/// Kept apart from utilisation on purpose: two measures on two scales belong in
/// two charts, never on two y-axes.
struct ReportTemperatureChart: View {
    let rows: [ReportRow]
    var height: CGFloat = 140

    var body: some View {
        ReportTwoSeriesLineChart(
            rows: rows,
            title: "Average temperature",
            unit: "°C",
            height: height,
            firstName: "CPU",
            secondName: "GPU",
            firstValue: { $0.averageTemperatureCpu },
            secondValue: { $0.averageTemperatureGpu }
        )
    }
}

// MARK: - Intraday curve

/// Minute resolution power for a single day. Uses time on the x axis rather
/// than the row labels, because it has far more points than the table.
struct ReportIntradayChart: View {
    let buckets: [MetricsHistoryBucket]
    let interval: DateInterval
    var height: CGFloat = 150

    var body: some View {
        ReportChartCard(title: "Power through the day", unit: "W", note: "one minute resolution") {
            let segments = segments()
            if segments.isEmpty {
                ReportChartEmptyState()
            } else {
                Chart {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        ForEach(segment, id: \.bucketStart) { bucket in
                            LineMark(
                                x: .value("Time", bucket.bucketStart),
                                y: .value("Power", bucket.averagePowerSys ?? 0),
                                series: .value("Run", index)
                            )
                            .foregroundStyle(ReportPalette.system)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                        }

                        // A stretch of a single recorded minute has no line to
                        // draw, so give it a marker of its own.
                        if segment.count == 1, let only = segment.first {
                            PointMark(
                                x: .value("Time", only.bucketStart),
                                y: .value("Power", only.averagePowerSys ?? 0)
                            )
                            .symbolSize(24)
                            .foregroundStyle(ReportPalette.system)
                        }
                    }
                }
                .chartXScale(domain: interval.start...interval.end)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 3)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: height)
            }
        }
    }

    /// Breaks the line wherever more than five minutes went unrecorded.
    private func segments() -> [[MetricsHistoryBucket]] {
        var segments: [[MetricsHistoryBucket]] = []
        var current: [MetricsHistoryBucket] = []
        var previousStart: Date?

        for bucket in buckets where bucket.metricsSeconds > 0 {
            if let previousStart,
                bucket.bucketStart.timeIntervalSince(previousStart) > 300
            {
                segments.append(current)
                current = []
            }
            current.append(bucket)
            previousStart = bucket.bucketStart
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }
}

// MARK: - Legend

/// Legend for charts whose series are styled directly rather than through a
/// foreground style scale.
struct ReportChartLegend: View {
    let items: [(color: Color, label: String)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.color)
                        .frame(width: 10, height: 10)
                    Text(item.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
