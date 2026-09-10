import Foundation

#if RIFTVM_ACCEPTANCE_HARNESS
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
        case unexpectedPinyinCommit

        var errorDescription: String? {
            switch self {
            case .timeout:
                "The Guest did not return Hyprland input diagnostics."
            case .stageTimeout(let stage):
                "Timed out waiting for \(stage). See the retained probe files in RiftVM Shared."
            case .unexpectedPinyinCommit:
                "Pinyin committed text did not match the expected result. See the retained committed.txt."
            case .focusLost:
                "The test window lost keyboard focus. Return to the temporary workspace before running the test again."
            case .shortcutUnavailable:
                "The focused Accessibility Command bridge could not send the lock shortcut."
            }
        }
    }

    private static let timeout: Duration = .seconds(20)

    /// Requires fcitx5-chinese-addons in the disposable guest. The probe restores
    /// its previous input-method profile and never installs packages.
    static func runPinyin(
        client: VMOmarchyGuestAgentClient,
        sharedDirectory: URL,
        diagnosticsDirectory: URL,
        xiaohe: Bool = false
    ) async throws {
        let inputMethod = xiaohe ? "shuangpin" : "pinyin"
        let directory = sharedDirectory.appending(path: ".riftvm-ime-\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let guest = "/mnt/riftvm-shared/\(directory.lastPathComponent)"
        let script = """
        #!/bin/bash
        set -eu
        d='\(guest)'
        wait_for_release() {
          for ((attempt=0; attempt<200; attempt++)); do
            [ ! -f "$d/$1" ] || return 0
            sleep 0.05
          done
          return 1
        }
        # Starting a shell command happens on Return down. Do not replace the
        # Wayland IM keyboard grab before the host has released that Return.
        wait_for_release launch-key-released
        test -f /usr/share/fcitx5/inputmethod/pinyin.conf
        hyprctl -j getoption input:kb_options > "$d/keyboard-options.json"
        python3 - "$d" <<'PY'
        import json, pathlib, sys
        d = pathlib.Path(sys.argv[1])
        original = json.loads((d / 'keyboard-options.json').read_text())['str']
        (d / 'keyboard-options.txt').write_text(original)
        configured = ','.join(x for x in original.split(',') if x != 'shift:both_capslock_cancel')
        (d / 'configured-keyboard-options.txt').write_text(configured)
        for name, value in [('apply', configured), ('restore', original)]:
            (d / ('keyboard-' + name + '.lua')).write_text('hl.config({ input = { kb_options = ' + json.dumps(value, ensure_ascii=False) + ' } })')
        PY
        case "$(fcitx5-remote 2>/dev/null || true)" in
          1|2) touch "$d/daemon-was-running" ;;
        esac
        case "$(systemctl --user show -p ActiveState --value omarchy-fcitx5.service 2>/dev/null || true)" in
          active|activating|reloading)
            touch "$d/service-was-running"
            systemctl --user stop omarchy-fcitx5.service
            ;;
        esac
        fcitx5-remote -e || true
        sleep 2
        cp ~/.config/fcitx5/profile "$d/profile.backup"
        mkdir -p ~/.config/fcitx5/conf
        if [ -f ~/.config/fcitx5/conf/pinyin.conf ]; then
          cp ~/.config/fcitx5/conf/pinyin.conf "$d/pinyin.backup"
        fi
        printf 'ShuangpinProfile=Xiaohe\\n' > ~/.config/fcitx5/conf/pinyin.conf
        restore() {
          if [ -f "$d/ready" ]; then
            wait_for_release input-keys-released || true
          fi
          if [ -n "${monitor_pid:-}" ]; then
            kill "$monitor_pid" 2>/dev/null || true
            wait "$monitor_pid" 2>/dev/null || true
          fi
          fcitx5-remote -e || true
          sleep 1
          cp "$d/profile.backup" ~/.config/fcitx5/profile
          if [ -f "$d/pinyin.backup" ]; then
            cp "$d/pinyin.backup" ~/.config/fcitx5/conf/pinyin.conf
          else
            rm -f ~/.config/fcitx5/conf/pinyin.conf
          fi
          hyprctl eval "$(cat "$d/keyboard-restore.lua")" > "$d/keyboard-restored.log"
          hyprctl -j getoption input:kb_options > "$d/keyboard-restored.json"
          python3 - "$d" <<'PY'
        import json, pathlib, sys
        d = pathlib.Path(sys.argv[1])
        assert json.loads((d / 'keyboard-restored.json').read_text())['str'] == (d / 'keyboard-options.txt').read_text()
        PY
          if [ -f "$d/service-was-running" ]; then
            systemctl --user start omarchy-fcitx5.service > "$d/restored.log" 2>&1
          elif [ -f "$d/daemon-was-running" ]; then
            fcitx5 -d > "$d/restored.log" 2>&1
          fi
          if [ -f "$d/service-was-running" ] || [ -f "$d/daemon-was-running" ]; then
            for ((attempt=0; attempt<100; attempt++)); do
              [ -z "$(fcitx5-remote -n 2>/dev/null)" ] || break
              sleep 0.05
            done
            test -n "$(fcitx5-remote -n 2>/dev/null)"
            fcitx5-remote -c
          fi
          touch "$d/restored"
        }
        trap restore EXIT
        # Omarchy's two-Shift CapsLock mapping changes the Shift release keysym
        # and breaks Fcitx modifier-only toggles (upstream issue #7440). Model
        # the user's documented Shift-toggle configuration, then restore it.
        hyprctl eval "$(cat "$d/keyboard-apply.lua")" > "$d/keyboard-configured.log"
        hyprctl -j getoption input:kb_options > "$d/keyboard-applied.json"
        python3 - "$d" <<'PY'
        import json, pathlib, sys
        d = pathlib.Path(sys.argv[1])
        assert json.loads((d / 'keyboard-applied.json').read_text())['str'] == (d / 'configured-keyboard-options.txt').read_text()
        PY
        cat > ~/.config/fcitx5/profile <<'PROFILE'
        [Groups/0]
        Name=Default
        Default Layout=us
        DefaultIM=\(inputMethod)
        [Groups/0/Items/0]
        Name=keyboard-us
        [Groups/0/Items/1]
        Name=\(inputMethod)
        [GroupOrder]
        0=Default
        PROFILE
        fcitx5 -d > "$d/fcitx.log" 2>&1
        sleep 3
        fcitx5-remote -s \(inputMethod)
        fcitx5-remote -o
        fcitx5-remote -n > "$d/engine.txt"
        (
          for ((attempt=0; attempt<400; attempt++)); do
            [ ! -f "$d/capture" ] || break
            sleep 0.05
          done
          test -f "$d/capture" || exit 1
          grim "$d/candidates.png"
        ) &
        candidate_pid=$!
        # Read only this disposable guest's synthetic keyboard; never grab it.
        # Kernel transitions distinguish delivery from compositor/IME behavior.
        python3 - "$d" <<'PY' > "$d/kernel-input.jsonl" 2>&1 &
        import json, os, pathlib, select, struct, sys, time
        devices = {}
        for event in pathlib.Path('/sys/class/input').glob('event*'):
            name = (event / 'device/name').read_text().strip()
            if name == 'RiftVM Keyboard':
                devices[os.open('/dev/input/' + event.name, os.O_RDONLY | os.O_NONBLOCK)] = name
        print(json.dumps({'devices': devices}), flush=True)
        (pathlib.Path(sys.argv[1]) / 'monitor-ready').touch()
        deadline = time.monotonic() + 65
        while devices and time.monotonic() < deadline:
            for fd in select.select(list(devices), [], [], 0.1)[0]:
                data = os.read(fd, 24 * 256)
                for offset in range(0, len(data), 24):
                    sec, usec, kind, code, value = struct.unpack('llHHi', data[offset:offset + 24])
                    print(json.dumps([time.time(), sec, usec, kind, code, value]), flush=True)
        PY
        monitor_pid=$!
        for ((attempt=0; attempt<100; attempt++)); do
          [ ! -f "$d/monitor-ready" ] || break
          sleep 0.05
        done
        test -f "$d/monitor-ready"
        touch "$d/ready"
        IFS= read -t 60 -e -r value
        printf '%s' "$value" > "$d/committed.txt"
        wait "$candidate_pid"
        """
        try Data(script.utf8).write(to: directory.appending(path: "probe.sh"))
        try await client.injectKeyChord(modifiers: [29], key: 46)
        // Fcitx input state belongs to the focused context. Keep the second
        // engine in the terminal whose state the preceding restore closed.
        // Opening another terminal can reactivate its independent IM context
        // and turn the command's Return into a preedit commit.
        if !xiaohe {
            try await client.injectKeyChord(modifiers: [125], key: 28)
        }
        try await Task.sleep(for: .seconds(2))
        try await client.typeUSASCII("bash \(guest)/probe.sh")
        try await Task.sleep(for: .milliseconds(100))
        try await client.injectKeyChord(modifiers: [], key: 28, transitionDelay: .milliseconds(60))
        try Data().write(to: directory.appending(path: "launch-key-released"))
        func waitFor(_ name: String) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !FileManager.default.fileExists(atPath: directory.appending(path: name).path) {
                guard ContinuousClock.now < deadline else { throw ProbeError.stageTimeout("Pinyin \(name)") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await waitFor("ready")
        let engine = try String(contentsOf: directory.appending(path: "engine.txt"), encoding: .utf8)
        guard engine.trimmingCharacters(in: .whitespacesAndNewlines) == inputMethod else {
            throw ProbeError.stageTimeout("active Pinyin engine")
        }
        try await client.typeUSASCII(xiaohe ? "nihcc" : "nihaoo")
        try await Task.sleep(for: .milliseconds(500))
        try await client.injectKeyChord(modifiers: [], key: 14) // Edit the preedit to nihao.
        try await Task.sleep(for: .milliseconds(500))
        try Data().write(to: directory.appending(path: "capture"))
        try await waitFor("candidates.png")
        try await client.injectKeyChord(modifiers: [], key: 57) // Commit candidate.
        try await Task.sleep(for: .milliseconds(500))
        // Exercise editing after commit as well as preedit editing. Readline
        // models a UTF-8-aware application editor rather than the terminal's
        // canonical byte-erase behavior.
        try await client.injectKeyChord(modifiers: [], key: 14)
        try await client.typeUSASCII(xiaohe ? "hc" : "hao")
        try await client.injectKeyChord(modifiers: [], key: 57)
        try await client.injectKeyChord(
            modifiers: [], key: 42, transitionDelay: .milliseconds(60)
        ) // Exercise a short physical-style Shift tap, below Fcitx's 250 ms timeout.
        try await client.typeUSASCII(" english-ok")
        try await client.injectKeyChord(modifiers: [], key: 28)
        try Data().write(to: directory.appending(path: "input-keys-released"))
        try await waitFor("committed.txt")
        try await waitFor("restored")
        let committed = try String(contentsOf: directory.appending(path: "committed.txt"), encoding: .utf8)
        guard committed == "你好 english-ok" else { throw ProbeError.unexpectedPinyinCommit }
        let report: [String: Any] = [
            "result": "passed", "engine": inputMethod, "scheme": xiaohe ? "Xiaohe" : "Pinyin", "englishSwitchVerified": true, "committed": committed,
            "backspaceVerified": true, "backspacePhase": "preedit-and-postcommit", "route": "guest-agent-uinput",
            "keyboardConfiguration": "Shift toggle without shift:both_capslock_cancel; original restored",
            "candidateScreenshot": directory.appending(path: "candidates.png").path,
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: diagnosticsDirectory.appending(path: xiaohe ? "xiaohe-input.json" : "pinyin-input.json"), options: .atomic)
    }

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

#endif
