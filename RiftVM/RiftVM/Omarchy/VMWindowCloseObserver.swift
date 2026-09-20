import AppKit
import SwiftUI

#if arch(arm64)
struct VMWindowCloseObserver: NSViewRepresentable {
    let rootPath: URL
    let shouldConfirm: () -> Bool
    let shouldBlock: () -> Bool
    let onCloseAttempt: () -> Void
    /// Guest canvases extend under the titlebar. Windows that keep their normal
    /// toolbar — the Omarchy workspace — opt out.
    var appliesGuestWindowChrome = true
    /// The Omarchy workspace keeps one display mode for the whole session — the
    /// screen the window is on — and scales that canvas into whatever size the
    /// window has. Opening full screen is what makes that mode native instead of
    /// scaled, so the window takes the screen once when it appears.
    var entersFullScreenOnAttach = false
    /// Bumped when the caller wants the window taken full screen now — the
    /// moment a guest starts running, for example. The attach-time flag above
    /// cannot do that, because a window that is already attached never re-runs
    /// its attach path.
    var fullScreenRequest = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rootPath: rootPath,
            appliesGuestWindowChrome: appliesGuestWindowChrome,
            entersFullScreenOnAttach: entersFullScreenOnAttach,
            shouldConfirm: shouldConfirm,
            shouldBlock: shouldBlock,
            onCloseAttempt: onCloseAttempt
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.rootPath = rootPath
        context.coordinator.appliesGuestWindowChrome = appliesGuestWindowChrome
        context.coordinator.entersFullScreenOnAttach = entersFullScreenOnAttach
        let requestsFullScreen = context.coordinator.fullScreenRequest != fullScreenRequest
        context.coordinator.fullScreenRequest = fullScreenRequest
        context.coordinator.shouldConfirm = shouldConfirm
        context.coordinator.shouldBlock = shouldBlock
        context.coordinator.onCloseAttempt = onCloseAttempt
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
            if requestsFullScreen { context.coordinator.enterFullScreenWhenReady() }
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var rootPath: URL
        var appliesGuestWindowChrome: Bool
        var entersFullScreenOnAttach: Bool
        var fullScreenRequest = 0
        var requestedFullScreen = false
        var shouldConfirm: () -> Bool
        var shouldBlock: () -> Bool
        var onCloseAttempt: () -> Void
        private weak var window: NSWindow?
        private var previousDelegate: NSWindowDelegate?

        init(
            rootPath: URL,
            appliesGuestWindowChrome: Bool,
            entersFullScreenOnAttach: Bool,
            shouldConfirm: @escaping () -> Bool,
            shouldBlock: @escaping () -> Bool,
            onCloseAttempt: @escaping () -> Void
        ) {
            self.rootPath = rootPath
            self.appliesGuestWindowChrome = appliesGuestWindowChrome
            self.entersFullScreenOnAttach = entersFullScreenOnAttach
            self.shouldConfirm = shouldConfirm
            self.shouldBlock = shouldBlock
            self.onCloseAttempt = onCloseAttempt
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            window.representedURL = rootPath.standardizedFileURL
            if appliesGuestWindowChrome {
                // Let the guest canvas occupy the titlebar-safe-area in full screen.
                // The toolbar still draws normally in windowed mode, while its
                // auto-hidden full-screen state no longer leaves white margins.
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.backgroundColor = .black
            }
            guard self.window !== window else { return }
            detach()
            self.window = window
            previousDelegate = window.delegate
            window.delegate = self
            if entersFullScreenOnAttach { enterFullScreenWhenReady() }
        }

        /// Takes the window full screen once it is on screen. Repeats a request
        /// that arrived while the window was already attached, and forgets the
        /// earlier attempt so a restarted guest can ask again.
        func enterFullScreenWhenReady() {
            guard let window else { return }
            requestedFullScreen = true
            // Give the window a beat to be on screen first: a transition
            // requested during the first layout is ignored.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
                guard let self, let window else { return }
                self.requestFullScreen(window, attempt: 0)
            }
        }

        /// Asking for full screen before the window is on screen is ignored, so
        /// retry briefly instead of firing once into the void.
        private func requestFullScreen(_ window: NSWindow, attempt: Int) {
            guard self.window === window, !window.styleMask.contains(.fullScreen) else { return }
            guard attempt < 12 else {
                RiftVMLog.info(
                    "Workspace window did not become visible for the full-screen request",
                    logger: RiftVMLog.graphics
                )
                return
            }
            let onScreen = window.isVisible && window.occlusionState.contains(.visible)
            if onScreen || attempt >= 6 {
                window.collectionBehavior.insert(.fullScreenPrimary)
                RiftVMLog.info(
                    "Workspace window entering full screen (attempt \(attempt) onScreen=\(onScreen))",
                    logger: RiftVMLog.graphics
                )
                window.toggleFullScreen(nil)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak window] in
                guard let self, let window else { return }
                self.requestFullScreen(window, attempt: attempt + 1)
            }
        }

        func detach() {
            if window?.delegate === self {
                window?.delegate = previousDelegate
            }
            if self.window !== nil { requestedFullScreen = false }
            window = nil
            previousDelegate = nil
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if shouldBlock() { return false }
            guard shouldConfirm() else {
                return previousDelegate?.windowShouldClose?(sender) ?? true
            }
            onCloseAttempt()
            return false
        }

        func window(
            _ window: NSWindow,
            willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
        ) -> NSApplication.PresentationOptions {
            let options = previousDelegate?.window?(
                window,
                willUseFullScreenPresentationOptions: proposedOptions
            ) ?? proposedOptions
            return options.union(.autoHideToolbar)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (previousDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if previousDelegate?.responds(to: aSelector) == true { return previousDelegate }
            return super.forwardingTarget(for: aSelector)
        }
    }
}
#endif
