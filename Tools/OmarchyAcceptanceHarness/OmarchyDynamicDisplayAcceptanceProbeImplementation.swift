import AppKit
import Foundation
import Virtualization

#if RIFTVM_ACCEPTANCE_HARNESS
@MainActor
enum OmarchyDynamicDisplayAcceptanceProbe {
    private static let timeout: Duration = .seconds(20)

    static func run(
        client: VMOmarchyGuestAgentClient,
        view: VZVirtualMachineView,
        sharedDirectory: URL
    ) async throws -> OmarchyDynamicDisplayRoundTrip {
        guard let window = view.window else { throw ProbeError.missingWindow }
        let nonce = UUID().uuidString.lowercased()
        let probeDirectory = sharedDirectory.appending(path: ".riftvm-display-\(nonce)")
        let guestDirectory = "/mnt/riftvm-shared/\(probeDirectory.lastPathComponent)"
        let originalContentSize = window.contentLayoutRect.size
        let originalFrame = window.frame
        defer {
            // contentLayoutRect excludes the toolbar; feeding it back into
            // setContentSize shrinks a full-size-content window on every run.
            window.setFrame(originalFrame, display: true)
            try? FileManager.default.removeItem(at: probeDirectory)
        }
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: false)
        try Data(script(guestDirectory: guestDirectory).utf8)
            .write(to: probeDirectory.appending(path: "probe.sh"))

        try await client.typeUSASCII("bash \(guestDirectory)/probe.sh\n")
        let before = try await waitForDisplay(at: probeDirectory.appending(path: "before.json"))

        let targetWidth: CGFloat = originalContentSize.width > 980 ? 880 : 1100
        let targetHeight: CGFloat = originalContentSize.height > 700 ? 640 : 760
        window.setContentSize(NSSize(width: targetWidth, height: targetHeight))
        try await Task.sleep(for: .milliseconds(500))
        // Retain backing-pixel evidence, but compare the Guest with the mode
        // that Custom VirGL requests from logical bounds (including alignment).
        let viewSize = view.convertToBacking(view.bounds).size
        let hostAfter = OmarchyDisplaySize(
            width: Int(viewSize.width.rounded()),
            height: Int(viewSize.height.rounded())
        )
        let requested = VMDisplayGeometry.guestResolution(for: view.bounds.size)
        let expectedGuest = OmarchyDisplaySize(width: Int(requested.width), height: Int(requested.height))
        NSLog("Custom VirGL display probe: screen=%@ original=%.0fx%.0f target=%.0fx%.0f actual=%.0fx%.0f guestBefore=%dx%d expected=%dx%d", window.screen?.localizedName ?? "unknown", originalContentSize.width, originalContentSize.height, targetWidth, targetHeight, view.bounds.width, view.bounds.height, before.width, before.height, expectedGuest.width, expectedGuest.height)
        try Data().write(to: probeDirectory.appending(path: "resize-go"), options: .atomic)
        let after = try await waitForDisplay(at: probeDirectory.appending(path: "after.json"))
        guard before != after else { throw ProbeError.resolutionUnchanged(before) }
        guard after == expectedGuest else {
            throw ProbeError.hostGuestMismatch(host: expectedGuest, guest: after)
        }
        return OmarchyDynamicDisplayRoundTrip(
            observedAt: Date(),
            guestBefore: before,
            guestAfter: after,
            hostViewAfter: hostAfter,
            expectedGuest: expectedGuest
        )
    }

    static func runAcrossDisplays(
        client: VMOmarchyGuestAgentClient,
        view: VZVirtualMachineView,
        sharedDirectory: URL,
        diagnosticsDirectory: URL
    ) async throws {
        guard let window = view.window else { throw ProbeError.missingWindow }
        let screens = NSScreen.screens
        guard screens.count > 1 else { throw ProbeError.timeout("a second physical display") }
        let originalFrame = window.frame
        defer { window.setFrame(originalFrame, display: true) }
        var observations: [[String: Any]] = []
        for cycle in 0..<3 {
            for screen in screens {
                try Task.checkCancellation()
                // Exercise focus loss without generating any input while hidden.
                window.orderOut(nil)
                try await Task.sleep(for: .milliseconds(200))
                window.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40))
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                try await Task.sleep(for: .seconds(1))
                guard window.screen === screen, window.isKeyWindow,
                      window.firstResponder === view else { throw ProbeError.missingWindow }
                try await OmarchyInputDiagnosticsAcceptanceProbe.verifyInteractiveDesktopEventually(
                    client: client, sharedDirectory: sharedDirectory, attempts: 3, timeoutPerAttempt: .seconds(8)
                )
                let result = try await run(client: client, view: view, sharedDirectory: sharedDirectory)
                observations.append([
                    "cycle": cycle, "display": screen.localizedName,
                    "maximumFramesPerSecond": screen.maximumFramesPerSecond,
                    "guestWidth": result.guestAfter.width, "guestHeight": result.guestAfter.height,
                    "hostWidth": result.hostViewAfter.width, "hostHeight": result.hostViewAfter.height,
                    "requestedGuestWidth": result.expectedGuest?.width ?? 0,
                    "requestedGuestHeight": result.expectedGuest?.height ?? 0,
                    "focusRecovered": true,
                ])
            }
        }
        let report: [String: Any] = ["schemaVersion": 1, "result": "passed", "observations": observations]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: diagnosticsDirectory.appending(path: "multi-display-focus.json"), options: .atomic)
    }

    private static func script(guestDirectory: String) -> String {
        """
        #!/usr/bin/env bash
        set -eu
        d='\(guestDirectory)'
        hyprctl monitors -j > "$d/before.json"
        while [ ! -f "$d/resize-go" ]; do sleep 0.1; done
        sleep 3
        hyprctl monitors -j > "$d/after.json"
        """
    }

    private static func waitForDisplay(at url: URL) async throws -> OmarchyDisplaySize {
        let deadline = ContinuousClock.now + timeout
        repeat {
            if let data = try? Data(contentsOf: url), !data.isEmpty,
               let size = try? decodeDisplay(data) { return size }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw ProbeError.timeout(url.lastPathComponent)
    }

    static func decodeDisplay(_ data: Data) throws -> OmarchyDisplaySize {
        guard let monitors = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let monitor = monitors.first(where: { ($0["disabled"] as? Bool) != true }),
              let width = monitor["width"] as? Int,
              let height = monitor["height"] as? Int,
              width > 0, height > 0 else { throw ProbeError.invalidMonitorJSON }
        return OmarchyDisplaySize(width: width, height: height)
    }

    enum ProbeError: LocalizedError {
        case hostGuestMismatch(host: OmarchyDisplaySize, guest: OmarchyDisplaySize)
        case invalidMonitorJSON
        case missingWindow
        case resolutionUnchanged(OmarchyDisplaySize)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .hostGuestMismatch(let host, let guest):
                "Guest display \(guest.width)x\(guest.height) does not match the requested Custom VirGL mode \(host.width)x\(host.height)."
            case .invalidMonitorJSON: "Hyprland returned invalid monitor JSON."
            case .missingWindow: "The Omarchy display has no Host window."
            case .resolutionUnchanged(let size):
                "Guest display remained \(size.width)x\(size.height) after Host resize."
            case .timeout(let file): "Timed out waiting for Guest display evidence \(file)."
            }
        }
    }
}

#endif
