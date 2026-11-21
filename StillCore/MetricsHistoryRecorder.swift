import AppKit
import Combine
import Foundation
import MacmonSwift

/// Feeds live metrics and battery readings into the history database while the
/// app runs. The helper covers the time the app is closed.
@MainActor
final class MetricsHistoryRecorder: ObservableObject {
    static let shared = MetricsHistoryRecorder()

    private static let heartbeatInterval: TimeInterval = 30

    private let service = MetricsHistoryService.shared
    private var aggregator = MetricsHistoryAggregator(source: .app)
    private var metricsSubscription: AnyCancellable?
    private var batterySubscription: AnyCancellable?
    private var terminationObserver: (any NSObjectProtocol)?
    private var lastHeartbeat: Date = .distantPast

    @Published private(set) var isRecording = false

    private init() {}

    func start() {
        guard !isRecording, AppSettings.historyRecordingEnabled else { return }
        isRecording = true

        metricsSubscription = AppDependencies.shared.metricsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] metrics in
                self?.record(metrics)
            }

        batterySubscription = BatteryTrackerService.shared.runtimeStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.record(batteryState: state)
            }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                MetricsHistoryRecorder.shared.flushOnTermination()
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        metricsSubscription = nil
        batterySubscription = nil
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        flushOnTermination()
    }

    func setRecordingEnabled(_ isEnabled: Bool) {
        AppSettings.historyRecordingEnabled = isEnabled
        if isEnabled {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Recording

    private func record(_ metrics: Metrics) {
        aggregator.add(Self.historySample(from: metrics, date: Date()))
        flushCompletedBuckets()
    }

    private func record(batteryState: BatteryRuntimeState?) {
        guard let batteryState else { return }
        let status = batteryState.batteryStatus
        aggregator.add(
            battery: BatteryHistorySample(
                date: Date(),
                currentCapacityMah: status.currentCapacityMah,
                maxCapacityMah: status.maxCapacityMah,
                isOnACPower: status.isOnACPower,
                isCharging: status.isCharging,
                isLowPowerMode: status.powerSaveMode
            ))
    }

    private func flushCompletedBuckets() {
        let now = Date()
        let completed = aggregator.drainCompleted(now: now)
        let needsHeartbeat = now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval

        guard !completed.isEmpty || needsHeartbeat else { return }
        if needsHeartbeat {
            lastHeartbeat = now
        }
        service.submit(completed, heartbeat: needsHeartbeat)
    }

    /// Writes the minute in progress so quitting does not lose it.
    private func flushOnTermination() {
        let pending = aggregator.drainAll()
        guard !pending.isEmpty else { return }
        service.flushSynchronously(pending)
    }

    // MARK: - Conversion

    static func historySample(from metrics: Metrics, date: Date) -> MetricsHistorySample {
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
            temperatureGpu: Double(metrics.temp.gpuTempAvg)
        )
    }

    /// Collapses per-tier frequencies into one figure, weighted by core count so
    /// a four-core tier does not outweigh an eight-core one.
    private static func cpuFrequency(_ tiers: [CpuTierMetrics]) -> Double {
        let totalWeight = tiers.reduce(0) { $0 + max(1, $1.cores.count) }
        if totalWeight == 0 { return 0 }
        let weighted = tiers.reduce(0.0) { $0 + Double($1.freqMHz) * Double(max(1, $1.cores.count)) }
        return weighted / Double(totalWeight)
    }
}
