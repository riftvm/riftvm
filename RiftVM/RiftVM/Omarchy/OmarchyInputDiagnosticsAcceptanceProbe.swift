import Foundation

@MainActor
enum OmarchyInputDiagnosticsAcceptanceProbe {
    struct LockCycle: Equatable {
        let lockedAt: Date
        let unlockedAt: Date
    }

    enum ProbeError: LocalizedError {
        case timeout
        case shortcutUnavailable
        case stageTimeout(String)
        case focusLost

        var errorDescription: String? {
            switch self {
            case .timeout:
                "The Guest did not return Hyprland input diagnostics."
            case .stageTimeout(let stage):
                "Timed out waiting for \(stage). See the retained probe files in RiftVM Shared."
            case .focusLost:
                "The test window lost keyboard focus. Return to the temporary workspace before running the test again."
            case .shortcutUnavailable:
                "The focused Accessibility Command bridge could not send the lock shortcut."
            }
        }
    }

    private static let timeout: Duration = .seconds(20)

    static func runContinuousInputBurst(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        diagnosticsDirectory: URL,
        sendTextBurst: (String) -> Bool,
        sendKeyRepeat: (Int) -> Bool
    ) async throws {
        let alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let payloads = (0..<10).map { index in
            "RiftVMQueueBurst\(index)-\(alphabet)-\(alphabet)-END"
        }
        let probeDirectory = sharedDirectory.appending(
            path: ".riftvm-continuous-input-\(UUID().uuidString.lowercased())"
        )
        let guestDirectory = "/mnt/riftvm-shared/\(probeDirectory.lastPathComponent)"
        let reportURL = diagnosticsDirectory.appending(path: "continuous-input-burst.json")
        var completed = false
        defer {
            if completed { try? FileManager.default.removeItem(at: probeDirectory) }
        }
        try FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)

        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        for (index, payload) in payloads.enumerated() {
            let resultURL = probeDirectory.appending(path: "sample-\(index).txt")
            let command = "printf '%s' '\(payload)' > \(guestDirectory)/sample-\(index).txt\n"
            guard sendTextBurst(command) else { throw ProbeError.shortcutUnavailable }
            let deadline = ContinuousClock.now + timeout
            repeat {
                if let actual = try? String(contentsOf: resultURL, encoding: .utf8),
                   actual == payload {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            guard let actual = try? String(contentsOf: resultURL, encoding: .utf8),
                  actual == payload else { throw ProbeError.timeout }
        }
        let repeatCount = 64
        let repeatURL = probeDirectory.appending(path: "key-repeat.txt")
        guard sendTextBurst(
            "IFS= read -r value; printf '%s' \"$value\" > \(guestDirectory)/key-repeat.txt\n"
        ), sendKeyRepeat(repeatCount), sendTextBurst("\n") else {
            throw ProbeError.shortcutUnavailable
        }
        let repeatDeadline = ContinuousClock.now + timeout
        repeat {
            if let actual = try? String(contentsOf: repeatURL, encoding: .utf8),
               actual == String(repeating: "a", count: repeatCount) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < repeatDeadline
        guard let repeated = try? String(contentsOf: repeatURL, encoding: .utf8),
              repeated == String(repeating: "a", count: repeatCount) else {
            throw ProbeError.timeout
        }
        guard sendTextBurst("exit\n") else { throw ProbeError.shortcutUnavailable }
        let report: [String: Any] = [
            "schemaVersion": 1,
            "result": "passed",
            "sampleCount": payloads.count,
            "charactersPerSample": payloads.first?.count ?? 0,
            "keyRepeatCount": repeatCount,
            "returnKeyVerified": true,
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "route": "AppKit-view-to-Guest-Agent-uinput",
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: reportURL, options: .atomic)
        completed = true
    }

    static func run(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        diagnosticsDirectory: URL
    ) async throws {
        let nonce = UUID().uuidString.lowercased()
        let stem = ".riftvm-input-diagnostics-\(nonce)"
        let scriptURL = sharedDirectory.appending(path: "\(stem).sh")
        let resultURL = sharedDirectory.appending(path: "\(stem).txt")
        let guestScript = "/mnt/riftvm-shared/\(scriptURL.lastPathComponent)"
        let guestResult = "/mnt/riftvm-shared/\(resultURL.lastPathComponent)"
        let retainedResult = diagnosticsDirectory.appending(path: "lock-input-diagnostics.txt")

        var completed = false
        defer {
            if completed {
                try? FileManager.default.removeItem(at: scriptURL)
                try? FileManager.default.removeItem(at: resultURL)
            }
        }
        try FileManager.default.createDirectory(
            at: diagnosticsDirectory,
            withIntermediateDirectories: true
        )
        try Data(probeScript(resultPath: guestResult).utf8).write(to: scriptURL, options: .atomic)

        // Omarchy's documented Super-Return binding opens the terminal. The
        // acceptance-only command then runs entirely inside the Guest and
        // writes its bounded diagnostics through the managed shared folder.
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guestScript)\n")

        let deadline = ContinuousClock.now + timeout
        repeat {
            if FileManager.default.fileExists(atPath: resultURL.path) {
                let data = try Data(contentsOf: resultURL)
                try data.write(to: retainedResult, options: .atomic)
                NSLog("Captured Guest lock/input diagnostics at %@", retainedResult.path)
                completed = true
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw ProbeError.stageTimeout("the Hyprland diagnostic command to finish")
    }

    static func runObservedLockCycle(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        sendLockShortcut: () -> Bool,
        sendUnlockSecret: () -> Bool,
        checkFocus: () throws -> Void = {}
    ) async throws -> LockCycle {
        let nonce = UUID().uuidString.lowercased()
        let probeDirectory = sharedDirectory.appending(path: ".riftvm-lock-cycle-\(nonce)")
        let guestDirectory = "/mnt/riftvm-shared/\(probeDirectory.lastPathComponent)"
        var completed = false
        defer {
            try? Data().write(to: probeDirectory.appending(path: "cancel"))
            if completed {
                try? FileManager.default.removeItem(at: probeDirectory)
            } else {
                NSLog("Retained failed Guest lock probe at %@", probeDirectory.path)
            }
        }
        try FileManager.default.createDirectory(
            at: probeDirectory,
            withIntermediateDirectories: false
        )
        try Data(lockWatcherScript(guestDirectory: guestDirectory).utf8).write(
            to: probeDirectory.appending(path: "watch-lock.sh"),
            options: .atomic
        )

        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guestDirectory)/watch-lock.sh\n")
        try await waitForFile(probeDirectory.appending(path: "ready"), stage: "the lock watcher to become ready", checkFocus: checkFocus)

        try checkFocus()
        guard sendLockShortcut() else { throw ProbeError.shortcutUnavailable }
        try await waitForFile(probeDirectory.appending(path: "locked"), stage: "the Guest to lock", checkFocus: checkFocus)
        let lockedAt = Date()
        // Keep the Omarchy lock screen alive for at least one authenticated Agent heartbeat.
        // This proves the product status channel observes the locked state in
        // addition to the Guest-side process watcher proving the UI transition.
        try await Task.sleep(for: .seconds(11))
        try checkFocus()
        guard sendUnlockSecret() else { throw ProbeError.shortcutUnavailable }
        try await waitForFile(probeDirectory.appending(path: "unlocked"), stage: "the Guest to unlock", checkFocus: checkFocus)
        // Lock state APIs can briefly or incorrectly report false after a
        // rejected password. Prove that a normal desktop shortcut and command
        // can actually execute before accepting the cycle as recovered.
        try await verifyInteractiveDesktopEventually(
            client: client,
            sharedDirectory: sharedDirectory,
            attempts: 3,
            timeoutPerAttempt: .seconds(8)
        )
        let unlockedAt = Date()
        completed = true
        return LockCycle(lockedAt: lockedAt, unlockedAt: unlockedAt)
    }

    static func sendDesktopNotification(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        title: String
    ) async throws {
        let nonce = UUID().uuidString.lowercased()
        let stem = ".riftvm-notification-\(nonce)"
        let scriptURL = sharedDirectory.appending(path: "\(stem).sh")
        let resultURL = sharedDirectory.appending(path: "\(stem).done")
        let guestScript = "/mnt/riftvm-shared/\(scriptURL.lastPathComponent)"
        let guestResult = "/mnt/riftvm-shared/\(resultURL.lastPathComponent)"
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        let script = """
        #!/bin/bash
        set -euo pipefail
        notify-send --app-name='RiftVM Omarchy Acceptance' --urgency=normal \
          '\(title)' 'Guest to macOS notification bridge'
        touch '\(guestResult)'
        """
        try Data(script.utf8).write(to: scriptURL, options: .atomic)
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guestScript)\n")
        try await waitForFile(resultURL)
    }

    static func verifyInteractiveDesktop(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        timeout: Duration = .seconds(8)
    ) async throws {
        let nonce = UUID().uuidString.lowercased()
        let stem = ".riftvm-interactive-\(nonce)"
        let scriptURL = sharedDirectory.appending(path: "\(stem).sh")
        let resultURL = sharedDirectory.appending(path: "\(stem).done")
        let guestScript = "/mnt/riftvm-shared/\(scriptURL.lastPathComponent)"
        let guestResult = "/mnt/riftvm-shared/\(resultURL.lastPathComponent)"
        defer {
            try? FileManager.default.removeItem(at: scriptURL)
            try? FileManager.default.removeItem(at: resultURL)
        }
        try Data("#!/bin/bash\nset -euo pipefail\ntouch '\(guestResult)'\n".utf8)
            .write(to: scriptURL, options: .atomic)
        try await client.injectKeyChord(modifiers: [125], key: 28)
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guestScript)\n")
        try await waitForFile(resultURL, timeout: timeout)
    }

    static func verifyInteractiveDesktopEventually(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        attempts: Int,
        timeoutPerAttempt: Duration,
        retryDelay: Duration = .seconds(2)
    ) async throws {
        precondition(attempts > 0)
        var finalError: Error?
        for attempt in 1...attempts {
            do {
                try await verifyInteractiveDesktop(
                    client: client,
                    sharedDirectory: sharedDirectory,
                    timeout: timeoutPerAttempt
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                finalError = error
                if attempt < attempts {
                    try await Task.sleep(for: retryDelay)
                }
            }
        }
        throw finalError ?? ProbeError.timeout
    }

    static func waitForFile(
        _ url: URL,
        timeout requestedTimeout: Duration = .seconds(20),
        stage: String = "the interactive desktop command to finish",
        checkFocus: () throws -> Void = {}
    ) async throws {
        let deadline = ContinuousClock.now + requestedTimeout
        repeat {
            try Task.checkCancellation()
            try checkFocus()
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        throw ProbeError.stageTimeout(stage)
    }

    nonisolated static func probeScript(resultPath: String) -> String {
        """
        #!/bin/bash
        set +e
        result='\(resultPath)'
        partial="$result.part"
        rm -f -- "$partial" "$result"
        {
          printf '%s\n' '=== hyprctl version ==='
          hyprctl version
          printf '%s\n' '=== hyprctl binds -j ==='
          hyprctl binds -j
          printf '%s\n' '=== hyprctl devices -j ==='
          hyprctl devices -j
          printf '%s\n' '=== hyprctl activewindow -j ==='
          hyprctl activewindow -j
          printf '%s\n' '=== omarchy shell ==='
          command -v omarchy-shell || true
          OMARCHY_SHELL_IPC_TIMEOUT=0.5s omarchy-shell lock status || true
          pgrep -a omarchy-shell || true
        } > "$partial" 2>&1
        mv -f -- "$partial" "$result"
        """
    }

    nonisolated static func lockWatcherScript(guestDirectory: String) -> String {
        """
        #!/bin/bash
        set +e
        d='\(guestDirectory)'
        command -v omarchy-shell > "$d/omarchy-shell-command.txt" 2>&1 || exit 1
        lock_state() {
          OMARCHY_SHELL_IPC_TIMEOUT=0.5s omarchy-shell lock isLocked 2> "$d/lock-query-error.txt"
        }
        for _ in $(seq 1 400); do
          [[ -d "$d" && ! -e "$d/cancel" ]] || exit 1
          state=$(lock_state)
          printf '%s\n' "$state" > "$d/lock-state.txt"
          if [[ $state == true || $state == false ]]; then touch "$d/ready"; break; fi
          sleep 0.05
        done
        [[ -e "$d/ready" ]] || exit 1
        wait_state() {
          local expected="$1"
          for _ in $(seq 1 1200); do
            [[ -d "$d" && ! -e "$d/cancel" ]] || return 1
            state=$(lock_state)
            printf '%s\\n' "$state" > "$d/lock-state.txt"
            [[ $state == "$expected" ]] && return 0
            sleep 0.05
          done
          return 1
        }
        wait_state true || exit 1
        touch "$d/locked"
        wait_state false || exit 1
        touch "$d/unlocked"
        """
    }
}
