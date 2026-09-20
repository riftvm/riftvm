//
//  AppDelegate.swift
//  RiftVM
//
//  Created by everettjf on 2022/6/24.
//

import Foundation
import Cocoa
import SwiftUI
import CryptoKit


@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var guiReadyAttempts = 0
    private var guiReadyEventMonitor: Any?
#if arch(arm64)
#endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
#if arch(arm64)
        if WorkspaceCreationStore.shared.isCreating {
            let alert = NSAlert()
            alert.messageText = "Omarchy is still being prepared"
            alert.informativeText = "Keep RiftVM open until creation finishes. Closing the window lets the download continue in the background."
            alert.addButton(withTitle: "Keep Creating")
            alert.runModal()
            return .terminateCancel
        }
        // Quitting must not kill a guest. Ask every live machine to save or shut
        // down first and reply once they are down, or after the bounded
        // force-stop fallback, so Quit cannot hang on a wedged guest.
        return VMLiveMachineCenter.shared.requestTermination()
#else
        return .terminateNow
#endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
#if arch(arm64)
        scheduleGUIReadyProbe()
#endif
    }

    private func scheduleGUIReadyProbe() {
        guard let markerPath = ProcessInfo.processInfo.environment["RIFTVM_GUI_READY_FILE"], !markerPath.isEmpty else { return }
        guiReadyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { [weak self] event in
            guard event.subtype.rawValue == 0x4556 else { return event }
            self?.writeGUIReadyMarker(markerPath: markerPath)
            return event
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.writeGUIReadyWhenVisible(markerPath: markerPath)
        }
    }

    private func writeGUIReadyWhenVisible(markerPath: String) {
        let visibleWindow = NSApp.windows.first { window in
            window.isVisible && window.contentViewController != nil && window.frame.width >= 800 && window.frame.height >= 600
        }
        guard let visibleWindow else {
            guiReadyAttempts += 1
            guard guiReadyAttempts < 100 else {
                RiftVMLog.error("The main SwiftUI window did not become visible for the GUI readiness probe.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.writeGUIReadyWhenVisible(markerPath: markerPath)
            }
            return
        }
        visibleWindow.makeKeyAndOrderFront(nil)
        let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: visibleWindow.windowNumber, context: nil, subtype: .init(0x4556), data1: 0, data2: 0
        )
        guard let event else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func writeGUIReadyMarker(markerPath: String) {
        guard let visibleWindow = NSApp.windows.first(where: {
            $0.isVisible && $0.contentViewController != nil && $0.frame.width >= 800 && $0.frame.height >= 600
        }) else { return }
        let record: [String: Any] = [
            "schemaVersion": 1,
            "pid": getpid(),
            "eventLoopResponsive": true,
            "windowVisible": visibleWindow.isVisible,
            "windowWidth": Int(visibleWindow.frame.width),
            "windowHeight": Int(visibleWindow.frame.height),
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: markerPath), options: .atomic)
            if let guiReadyEventMonitor {
                NSEvent.removeMonitor(guiReadyEventMonitor)
                self.guiReadyEventMonitor = nil
            }
        } catch {
            RiftVMLog.error("Could not write GUI readiness marker: \(error.localizedDescription)")
        }
    }

}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
