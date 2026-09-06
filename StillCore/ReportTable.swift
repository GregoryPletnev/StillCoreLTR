import SwiftUI

/// One column of the report table. The same definitions drive the window and
/// the printed page, so the two can never disagree.
struct ReportTableColumn: Identifiable {
    let id: String
    let title: String
    let width: CGFloat
    var isLeading = false
    let value: (ReportRow) -> String
    let total: (MetricsHistoryBucket) -> String

    nonisolated(unsafe) static let all: [ReportTableColumn] = [
        ReportTableColumn(
            id: "period", title: "Period", width: 104, isLeading: true,
            value: { $0.label }, total: { _ in "Total" }),
        ReportTableColumn(
            id: "energy", title: "System", width: 74,
            value: { ReportFormat.energy($0.bucket.energySysWh) },
            total: { ReportFormat.energy($0.energySysWh) }),
        ReportTableColumn(
            id: "average", title: "Avg", width: 62,
            value: { ReportFormat.power($0.bucket.averagePowerSys) },
            total: { ReportFormat.power($0.averagePowerSys) }),
        ReportTableColumn(
            id: "peak", title: "Peak", width: 62,
            value: { ReportFormat.power($0.bucket.powerSysMax > 0 ? $0.bucket.powerSysMax : nil) },
            total: { ReportFormat.power($0.powerSysMax > 0 ? $0.powerSysMax : nil) }),
        ReportTableColumn(
            id: "cpu", title: "CPU", width: 66,
            value: { ReportFormat.energy($0.bucket.energyCpuWh) },
            total: { ReportFormat.energy($0.energyCpuWh) }),
        ReportTableColumn(
            id: "gpu", title: "GPU", width: 66,
            value: { ReportFormat.energy($0.bucket.energyGpuWh) },
            total: { ReportFormat.energy($0.energyGpuWh) }),
        ReportTableColumn(
            id: "ane", title: "ANE", width: 66,
            value: { ReportFormat.energy($0.bucket.energyAneWh) },
            total: { ReportFormat.energy($0.energyAneWh) }),
        ReportTableColumn(
            id: "cpuUsage", title: "CPU use", width: 62,
            value: { ReportFormat.usage($0.bucket.averageCpuUsage) },
            total: { ReportFormat.usage($0.averageCpuUsage) }),
        ReportTableColumn(
            id: "gpuUsage", title: "GPU use", width: 62,
            value: { ReportFormat.usage($0.bucket.averageGpuUsage) },
            total: { ReportFormat.usage($0.averageGpuUsage) }),
        ReportTableColumn(
            id: "cpuTemp", title: "CPU °", width: 54,
            value: { ReportFormat.temperature($0.bucket.averageTemperatureCpu) },
            total: { ReportFormat.temperature($0.averageTemperatureCpu) }),
        ReportTableColumn(
            id: "gpuTemp", title: "GPU °", width: 54,
            value: { ReportFormat.temperature($0.bucket.averageTemperatureGpu) },
            total: { ReportFormat.temperature($0.averageTemperatureGpu) }),
        ReportTableColumn(
            id: "drained", title: "Drained", width: 70,
            value: { ReportFormat.capacity($0.bucket.batteryDrainMah) },
            total: { ReportFormat.capacity($0.batteryDrainMah) }),
        ReportTableColumn(
            id: "unplugged", title: "Unplugged", width: 74,
            value: { ReportFormat.duration($0.bucket.onBatterySeconds) },
            total: { ReportFormat.duration($0.onBatterySeconds) }),
        ReportTableColumn(
            id: "coverage", title: "Covered", width: 64,
            value: { ReportFormat.percent($0.coverage) },
            total: { ReportFormat.duration($0.metricsSeconds) }),
    ]

    static var totalWidth: CGFloat {
        all.reduce(0) { $0 + $1.width } + CGFloat(all.count) * 8
    }
}

/// Static table used both on screen and on paper. Built from stacks rather
/// than `Table`, because only a plain view hierarchy renders into a page image.
struct ReportTableView: View {
    let rows: [ReportRow]
    let total: MetricsHistoryBucket
    var columns: [ReportTableColumn] = ReportTableColumn.all
    var fontSize: CGFloat = 11
    var showsTotal = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                line(
                    // Zeros would read as measured idle, so a row with no
                    // coverage shows dashes instead.
                    values: columns.map { row.hasData || $0.isLeading ? $0.value(row) : "—" },
                    isDimmed: !row.hasData,
                    background: index.isMultiple(of: 2)
                        ? Color.clear : Color.primary.opacity(0.04)
                )
            }
            if showsTotal {
                Divider()
                line(
                    values: columns.map { $0.total(total) },
                    isDimmed: false,
                    background: Color.clear,
                    weight: .semibold
                )
            }
        }
        .font(.system(size: fontSize).monospacedDigit())
    }

    private var header: some View {
        HStack(spacing: 8) {
            ForEach(columns) { column in
                Text(column.title)
                    .frame(
                        width: column.width,
                        alignment: column.isLeading ? .leading : .trailing)
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func line(
        values: [String],
        isDimmed: Bool,
        background: Color,
        weight: Font.Weight = .regular
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(zip(columns, values)), id: \.0.id) { column, value in
                Text(value)
                    .frame(
                        width: column.width,
                        alignment: column.isLeading ? .leading : .trailing)
            }
        }
        .fontWeight(weight)
        .foregroundStyle(isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .padding(.vertical, 3)
        .background(background)
    }
}
