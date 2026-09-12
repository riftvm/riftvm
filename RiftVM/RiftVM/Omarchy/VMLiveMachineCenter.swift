//
//  VMLiveMachineCenter.swift
//  RiftVM
//
//  App-level view of the machines that are alive in this process.
//
//  The workspace windows own the real lifecycle (`VMRuntimeState` for macOS
//  guests, `OmarchyMachineLifecycle` for Omarchy). They publish a small control
//  surface here so the surfaces that outlive a window — the menu bar item and
//  the quit path — can show what is running and ask it to stop.
//
//  This file sits beside OmarchyApplicationTermination.swift because the Xcode
//  target synchronizes the Omarchy folder; the types are app-level, shared by
//  both guest kinds.
//

import AppKit
import SwiftUI
import Observation

#if arch(arm64)

/// A workspace machine that is alive in this process.
@MainActor
@Observable
final class VMLiveMachine: Identifiable {
    let id = UUID()
    let rootPath: URL
    let name: String

    /// User-facing state, e.g. "Running" or "Stopping".
    var status: String
    var canPause = false
    var canResume = false
    var canStop = false
    /// macOS guests can persist their state, so quitting can save instead of
    /// just shutting the guest down. Linux guests cannot.
    var canSaveAndStop = false
    /// The guest reported that it stopped; the owning window retires the entry.
    var hasStopped = false

    @ObservationIgnored var pauseAction: () -> Void = {}
    @ObservationIgnored var resumeAction: () -> Void = {}
    @ObservationIgnored var stopAction: () -> Void = {}
    @ObservationIgnored var saveAndStopAction: () -> Void = {}
    @ObservationIgnored var forceStopAction: () -> Void = {}

    init(rootPath: URL, name: String, status: String = "Running") {
        self.rootPath = rootPath.standardizedFileURL
        self.name = name
        self.status = status
    }

    /// Asks the guest to end cleanly, preferring a saved state when the guest
    /// supports it. Returns the line the quit panel shows while that happens.
    @discardableResult
    func prepareForTermination() -> String {
        if canSaveAndStop {
            saveAndStopAction()
            return "Saving \(name)…"
        }
        if canStop { stopAction() }
        return "Stopping \(name)…"
    }
}

/// Tracks the live machines and drains them before the app exits, so a guest is
/// never killed by process teardown.
@MainActor
@Observable
final class VMLiveMachineCenter {
    static let shared = VMLiveMachineCenter()

    private(set) var machines: [VMLiveMachine] = []

    @ObservationIgnored private let reply: @MainActor (Bool) -> Void
    @ObservationIgnored private let showProgress: @MainActor (String) -> Void
    @ObservationIgnored private let updateProgress: @MainActor (String) -> Void
    @ObservationIgnored private let hideProgress: @MainActor () -> Void
    @ObservationIgnored private let scheduleTimeout: @MainActor (DispatchWorkItem) -> Void

    private var terminating = false
    private var timeout: DispatchWorkItem?

    /// True between `applicationShouldTerminate` and the reply, so surfaces can
    /// tell a quit apart from an ordinary window close.
    var isTerminating: Bool { terminating }

    init(
        reply: @escaping @MainActor (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) },
        showProgress: @escaping @MainActor (String) -> Void = { VMQuitProgressPanel.shared.show(message: $0) },
        updateProgress: @escaping @MainActor (String) -> Void = { VMQuitProgressPanel.shared.update(message: $0) },
        hideProgress: @escaping @MainActor () -> Void = { VMQuitProgressPanel.shared.hide() },
        scheduleTimeout: @escaping @MainActor (DispatchWorkItem) -> Void = {
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: $0)
        }
    ) {
        self.reply = reply
        self.showProgress = showProgress
        self.updateProgress = updateProgress
        self.hideProgress = hideProgress
        self.scheduleTimeout = scheduleTimeout
    }

    // MARK: - Registration

    func register(_ machine: VMLiveMachine) {
        machines.removeAll { $0.rootPath == machine.rootPath }
        machines.append(machine)
    }

    func unregister(_ machine: VMLiveMachine) {
        guard machines.contains(where: { $0 === machine }) else { return }
        machines.removeAll { $0 === machine }
        guard terminating else { return }
        if machines.isEmpty {
            finishTermination()
        } else {
            updateProgress(Self.progressMessage(for: machines))
        }
    }

    func machine(for rootPath: URL) -> VMLiveMachine? {
        let target = rootPath.standardizedFileURL
        return machines.first { $0.rootPath == target }
    }

    // MARK: - Quit

    /// Called from `applicationShouldTerminate`. Returns `.terminateNow` when
    /// nothing is running and `.terminateLater` while the guests stop.
    func requestTermination() -> NSApplication.TerminateReply {
        guard !machines.isEmpty else { return .terminateNow }
        guard !terminating else { return .terminateLater }
        terminating = true
        let targets = machines
        showProgress(Self.progressMessage(for: targets))
        for machine in targets { machine.prepareForTermination() }
        let work = DispatchWorkItem { [weak self] in self?.forceTermination() }
        timeout = work
        scheduleTimeout(work)
        return .terminateLater
    }

    /// A guest did not stop in time. Stop the framework machine and let the
    /// process exit; this is the same bounded fallback the window close path
    /// uses, and it keeps Quit from hanging on a wedged guest.
    private func forceTermination() {
        for machine in machines where !machine.hasStopped { machine.forceStopAction() }
        finishTermination()
    }

    private func finishTermination() {
        guard terminating else { return }
        terminating = false
        timeout?.cancel()
        timeout = nil
        hideProgress()
        reply(true)
    }

    private static func progressMessage(for machines: [VMLiveMachine]) -> String {
        guard let machine = machines.first else { return "Stopping RiftVM…" }
        guard machines.count == 1 else { return "Stopping \(machines.count) workspaces…" }
        return machine.canSaveAndStop ? "Saving \(machine.name)…" : "Stopping \(machine.name)…"
    }
}

/// The panel shown while the quit path drains the live machines. It is its own
/// window so that quitting from the Dock or the menu bar item shows the same
/// feedback as quitting with a workspace window open — the app never just
/// vanishes while a guest is still shutting down.
@MainActor
final class VMQuitProgressPanel {
    static let shared = VMQuitProgressPanel()

    private var window: NSWindow?
    private var label: NSTextField?

    func show(message: String) {
        let window = window ?? makeWindow()
        self.window = window
        label?.stringValue = message
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(message: String) {
        label?.stringValue = message
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        label = nil
    }

    private func makeWindow() -> NSWindow {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 13)
        text.lineBreakMode = .byTruncatingTail
        label = text

        let stack = NSStackView(views: [spinner, text])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            content.heightAnchor.constraint(equalToConstant: 84),
        ])

        // No close button: the quit is already in flight and cannot be undone.
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "RiftVM"
        window.contentView = content
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        return window
    }
}

#endif
