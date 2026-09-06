import SwiftUI

/// Page layout constants shared by the printer and the PDF export.
enum ReportPageLayout {
    static let margin: CGFloat = 36
    /// A4 landscape in points. Overridden by the paper the user picks when
    /// printing; the PDF export uses this.
    static let defaultPageSize = CGSize(width: 842, height: 595)

    static func contentSize(for pageSize: CGSize) -> CGSize {
        CGSize(
            width: pageSize.width - margin * 2,
            height: pageSize.height - margin * 2)
    }
}

/// Header printed at the top of every page.
private struct ReportPageHeader: View {
    let report: Report
    let isFirstPage: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isFirstPage ? 4 : 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(report.period.title())
                    .font(.system(size: isFirstPage ? 20 : 13, weight: .semibold))
                Spacer()
                Text(report.hardwareSummary)
                    .font(.system(size: isFirstPage ? 12 : 10))
                    .foregroundStyle(.secondary)
            }
            if isFirstPage {
                HStack(spacing: 8) {
                    Text(report.period.subtitle())
                    Text("·")
                    Text("\(report.period.kind.title) report")
                    Text("·")
                    Text("Generated \(Self.timestamp(report.generatedAt))")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Footer with the page number, so a stack of printed sheets stays in order.
private struct ReportPageFooter: View {
    let pageNumber: Int
    let pageCount: Int

    var body: some View {
        HStack {
            Text("StillCore")
            Spacer()
            Text("Page \(pageNumber) of \(pageCount)")
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }
}

/// The summary figures, laid out as a row of tiles.
struct ReportHighlightsView: View {
    let highlights: [Report.Highlight]
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 10 : 12) {
            ForEach(highlights) { highlight in
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlight.title)
                        .font(.system(size: compact ? 9 : 11))
                        .foregroundStyle(.secondary)
                    Text(highlight.value)
                        .font(.system(size: compact ? 17 : 20, weight: .semibold))
                        .monospacedDigit()
                    Text(highlight.detail)
                        .font(.system(size: compact ? 9 : 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Splits a report into fixed-size pages.
///
/// Charts and the table are placed as whole blocks, so no chart is cut in half
/// and no table row is split across a page break.
@MainActor
enum ReportPageBuilder {
    static func pages(for report: Report, pageSize: CGSize) -> [AnyView] {
        let content = ReportPageLayout.contentSize(for: pageSize)
        let tableScale = min(1, content.width / ReportTableColumn.totalWidth)

        var blocks: [AnyView] = [
            AnyView(ReportHighlightsView(highlights: report.highlights())),
            AnyView(ReportEnergyChart(rows: report.rows, height: 150)),
            AnyView(ReportPowerChart(rows: report.rows, height: 120)),
        ]

        if !report.intraday.isEmpty {
            blocks.append(
                AnyView(
                    ReportIntradayChart(
                        buckets: report.intraday,
                        interval: report.periodInterval,
                        height: 120)))
        }

        blocks.append(AnyView(ReportUtilisationChart(rows: report.rows, height: 110)))
        blocks.append(AnyView(ReportTemperatureChart(rows: report.rows, height: 110)))
        if report.total.batterySeconds > 0 {
            blocks.append(AnyView(ReportBatteryChart(rows: report.rows, height: 110)))
        }

        // Two chart blocks plus the summary fill a landscape page comfortably.
        let chartPages = stride(from: 0, to: blocks.count, by: 3).map { start in
            Array(blocks[start..<min(start + 3, blocks.count)])
        }

        let rowsPerPage = max(1, Int((content.height - 90) / (17 * tableScale)))
        let tableChunks = stride(from: 0, to: report.rows.count, by: rowsPerPage).map { start in
            Array(report.rows[start..<min(start + rowsPerPage, report.rows.count)])
        }

        let pageCount = chartPages.count + max(1, tableChunks.count)
        var pages: [AnyView] = []

        for (index, page) in chartPages.enumerated() {
            pages.append(
                AnyView(
                    ReportPage(
                        report: report,
                        pageNumber: pages.count + 1,
                        pageCount: pageCount,
                        pageSize: pageSize
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(page.enumerated()), id: \.offset) { _, block in
                                block
                            }
                            if index == chartPages.count - 1 && tableChunks.isEmpty {
                                Spacer(minLength: 0)
                            }
                        }
                    }))
        }

        for (index, chunk) in tableChunks.enumerated() {
            pages.append(
                AnyView(
                    ReportPage(
                        report: report,
                        pageNumber: pages.count + 1,
                        pageCount: pageCount,
                        pageSize: pageSize
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(
                                tableChunks.count > 1
                                    ? "Detail (\(index + 1)/\(tableChunks.count))" : "Detail"
                            )
                            .font(.headline)
                            ReportTableView(
                                rows: chunk,
                                total: report.total,
                                fontSize: 11,
                                showsTotal: index == tableChunks.count - 1
                            )
                            .scaleEffect(tableScale, anchor: .topLeading)
                            .frame(
                                width: ReportTableColumn.totalWidth * tableScale,
                                alignment: .topLeading)
                            Spacer(minLength: 0)
                        }
                    }))
        }

        if pages.isEmpty {
            pages.append(
                AnyView(
                    ReportPage(
                        report: report, pageNumber: 1, pageCount: 1, pageSize: pageSize
                    ) {
                        Text("No data recorded for this period")
                            .foregroundStyle(.secondary)
                    }))
        }
        return pages
    }
}

/// One printed sheet: header, body, footer, on an opaque white background.
private struct ReportPage<Content: View>: View {
    let report: Report
    let pageNumber: Int
    let pageCount: Int
    let pageSize: CGSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReportPageHeader(report: report, isFirstPage: pageNumber == 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ReportPageFooter(pageNumber: pageNumber, pageCount: pageCount)
        }
        .padding(ReportPageLayout.margin)
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .background(Color.white)
        // Paper is white whatever the screen is set to, so the page is always
        // composed in the light appearance.
        .environment(\.colorScheme, .light)
    }
}
