import AppKit
import SwiftUI

/// Keeps the activation policy consistent between the menu bar window and the
/// report window. The app stays an accessory until something needs a real
/// window with a menu bar.
@MainActor
enum AppActivationPolicy {
    private static var requesters: Set<String> = []

    static func setRegular(_ isRegular: Bool, for requester: String) {
        if isRegular {
            requesters.insert(requester)
        } else {
            requesters.remove(requester)
        }

        let desired: NSApplication.ActivationPolicy = requesters.isEmpty ? .accessory : .regular
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
        }
    }
}

/// Owns the single report window.
@MainActor
final class ReportWindowController: NSObject, NSWindowDelegate {
    static let shared = ReportWindowController()

    private static let requesterName = "report"
    private static let minSize = CGSize(width: 960, height: 680)

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show() {
        if let window {
            AppActivationPolicy.setRegular(true, for: Self.requesterName)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.minSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "StillCore Report"
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = NSHostingView(rootView: ReportView())
        window.center()
        window.setFrameAutosaveName("StillCoreReportWindow")

        self.window = window

        AppActivationPolicy.setRegular(true, for: Self.requesterName)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        AppActivationPolicy.setRegular(false, for: Self.requesterName)
    }
}
