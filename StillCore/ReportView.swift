import AppKit
import SwiftUI

@MainActor
final class ReportViewModel: ObservableObject {
    @Published var periodKind: ReportPeriodKind = .day {
        didSet {
            guard oldValue != periodKind else { return }
            period = period.converted(to: periodKind)
            reload()
        }
    }
    @Published private(set) var period: ReportPeriod = .current(.day)
    @Published private(set) var report: Report?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage = ""
    @Published private(set) var availableRange: DateInterval?

    private var loadTask: Task<Void, Never>?

    /// The next period is only reachable once it has started.
    var canShiftForward: Bool {
        !period.isCurrent()
    }

    var isShowingCurrentPeriod: Bool {
        period.isCurrent()
    }

    func shift(_ steps: Int) {
        period = period.shifted(by: steps)
        reload()
    }

    func goToNow() {
        period = .current(periodKind)
        reload()
    }

    func reload() {
        loadTask?.cancel()
        isLoading = true

        let period = period
        let hardwareSummary = Self.hardwareSummary()

        loadTask = Task { [weak self] in
            let service = MetricsHistoryService.shared
            do {
                let report = try await service.report(
                    for: period, hardwareSummary: hardwareSummary)
                let range = await service.availableRange()
                guard !Task.isCancelled else { return }
                self?.apply(report: report, range: range)
            } catch {
                guard !Task.isCancelled else { return }
                self?.apply(error: error.localizedDescription)
            }
        }
    }

    private func apply(report: Report, range: DateInterval?) {
        self.report = report
        availableRange = range
        errorMessage = ""
        isLoading = false
    }

    private func apply(error: String) {
        report = nil
        errorMessage = error
        isLoading = false
    }

    private static func hardwareSummary() -> String {
        let dependencies = AppDependencies.shared
        let chip = dependencies.chipName ?? "Apple Silicon"
        return dependencies.socSummary.isEmpty ? chip : "\(chip) · \(dependencies.socSummary)"
    }
}

struct ReportView: View {
    @StateObject private var model = ReportViewModel()
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
            Divider()
            HistoryFooter(model: model)
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear { model.reload() }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } })
        ) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $model.periodKind) {
                ForEach(ReportPeriodKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            HStack(spacing: 2) {
                Button {
                    model.shift(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Previous \(model.periodKind.title.lowercased())")

                Button {
                    model.shift(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canShiftForward)
                .help("Next \(model.periodKind.title.lowercased())")
            }

            Button("Now") {
                model.goToNow()
            }
            .disabled(model.isShowingCurrentPeriod)

            VStack(alignment: .leading, spacing: 0) {
                Text(model.period.title())
                    .font(.headline)
                Text(model.period.subtitle())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                run { try ReportExporter.print($0) }
            } label: {
                Label("Print", systemImage: "printer")
            }
            .disabled(model.report == nil)
            .keyboardShortcut("p", modifiers: .command)

            Button("PDF") {
                run { try ReportExporter.exportPDF($0) }
            }
            .disabled(model.report == nil)

            Button("CSV") {
                run { ReportExporter.exportCSV($0) }
            }
            .disabled(model.report == nil)
        }
        .padding(12)
    }

    private func run(_ action: (Report) throws -> Void) {
        guard let report = model.report else { return }
        do {
            try action(report)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.errorMessage.isEmpty {
            message(model.errorMessage)
        } else if let report = model.report {
            if report.hasData {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ReportHighlightsView(highlights: report.highlights())
                            .padding(.horizontal, 4)

                        ReportEnergyChart(rows: report.rows)
                        ReportPowerChart(rows: report.rows)

                        if !report.intraday.isEmpty {
                            ReportIntradayChart(
                                buckets: report.intraday,
                                interval: report.periodInterval)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            ReportUtilisationChart(rows: report.rows)
                            ReportTemperatureChart(rows: report.rows)
                        }

                        if report.total.batterySeconds > 0 {
                            ReportBatteryChart(rows: report.rows)
                        }

                        detailTable(report)
                    }
                    .padding(12)
                }
            } else {
                message(emptyMessage(for: report))
            }
        } else {
            Color.clear
        }
    }

    private func detailTable(_ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Detail")
                .font(.headline)
            ScrollView(.horizontal) {
                ReportTableView(rows: report.rows, total: report.total)
                    .padding(.bottom, 4)
            }
        }
        .padding(12)
        .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private func emptyMessage(for report: Report) -> String {
        guard let range = model.availableRange else {
            return "No history yet. StillCore starts recording as soon as it runs, "
                + "and the battery helper keeps recording while it is closed."
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "Nothing recorded for this period. History starts on "
            + formatter.string(from: range.start) + "."
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Where the history stands and how to manage it. History grows on disk on its
/// own, so the window that reads it is also where it can be turned off or
/// cleared.
private struct HistoryFooter: View {
    @ObservedObject var model: ReportViewModel
    @ObservedObject private var recorder = MetricsHistoryRecorder.shared
    @State private var storageBytes: Int64 = 0
    @State private var isConfirmingClear = false

    var body: some View {
        HStack(spacing: 12) {
            Toggle(
                "Record history",
                isOn: Binding(
                    get: { recorder.isRecording },
                    set: { recorder.setRecordingEnabled($0) })
            )
            .toggleStyle(.checkbox)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Clear History...") {
                isConfirmingClear = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .task(id: model.availableRange) {
            storageBytes = await MetricsHistoryService.shared.storageByteCount()
        }
        .confirmationDialog(
            "Delete all recorded history?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    try? await MetricsHistoryService.shared.clearHistory()
                    model.reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every stored measurement is removed. This cannot be undone.")
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let start = model.availableRange?.start {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            parts.append("History since \(formatter.string(from: start))")
        } else {
            parts.append("No history yet")
        }
        if storageBytes > 0 {
            parts.append(
                ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }
}
