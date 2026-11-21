import Foundation

func runBatteryTracker() -> Never {
    let historyRecorder = HelperHistoryRecorder()
    BatteryTrackerEngine().run { batteryStatus, now in
        historyRecorder.record(batteryStatus: batteryStatus, now: now)
    }
}

runBatteryTracker()
