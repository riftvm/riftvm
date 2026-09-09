import AVFoundation
import CoreGraphics
import UserNotifications
import XCTest
@testable import RiftVM

final class RiftVMOmarchyTests: XCTestCase {
    func testAcceptanceOnlyTargetsTheExplicitTemporaryWorkspace() {
        let target = VMOmarchyWorkspaceLayout(applicationSupportRoot: URL(filePath: "/tmp/riftvm-acceptance-scope.riftvm"))
        let other = VMOmarchyWorkspaceLayout(applicationSupportRoot: URL(filePath: "/tmp/riftvm-other.riftvm"))
        let personal = VMOmarchyWorkspaceLayout(applicationSupportRoot: URL(filePath: NSHomeDirectory()).appending(path: "RiftVM Virtual Machines/Omarchy.riftvm"))
        let environment = [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: target.applicationSupportRoot.path,
        ]
        XCTAssertEqual(OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(target, environment: environment), OmarchyWorkspaceConfiguration.acceptanceHarnessIncluded)
        let directoryURL = VMOmarchyWorkspaceLayout(applicationSupportRoot: URL(fileURLWithPath: target.applicationSupportRoot.path, isDirectory: true))
        XCTAssertEqual(OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(directoryURL, environment: environment), OmarchyWorkspaceConfiguration.acceptanceHarnessIncluded)
        XCTAssertFalse(OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(other, environment: environment))
        XCTAssertFalse(OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(personal, environment: environment))
        XCTAssertFalse(OmarchyWorkspaceConfiguration.isAcceptanceWorkspace(target, environment: [:]))
    }

    @MainActor
    func testAcceptanceFailureDoesNotChangeVirtualMachinePhase() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        var phases: [OmarchyVirtualMachineView.Phase] = []
        var failures: [String] = []
        let coordinator = OmarchyVirtualMachineRepresentable.Coordinator(
            sessionID: UUID(), layout: layout, requiredGuestCapabilities: [],
            clipboardEnabled: false, notificationsEnabled: false,
            keyboardIntegrationChanged: { _ in }, integrationChanged: { _ in },
            sharedFolderProbeChanged: { _ in }, clipboardProbeChanged: { _ in },
            dynamicDisplayProbeChanged: { _ in }, ownerProvisioningCompleted: { _, _ in },
            ownerProvisioningProgressChanged: { _ in },
            phaseChanged: { phases.append($0) }, acceptanceFailureChanged: { failures.append($0) }
        )
        coordinator.reportAcceptanceFailure("Lock watcher did not become ready")
        coordinator.reportAcceptanceFailure("A later callback must not overwrite the first failure")
        XCTAssertTrue(phases.isEmpty)
        XCTAssertEqual(failures, ["Lock watcher did not become ready"])
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: layout.diagnostics.appending(path: "acceptance-failure.json"))) as? [String: Any])
        XCTAssertEqual(report["result"] as? String, "failed")
        XCTAssertEqual(report["message"] as? String, failures.first)
    }

    #if RIFTVM_ACCEPTANCE_HARNESS
    @MainActor
    func testProbeTimeoutNamesTheFailedStage() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try await OmarchyInputDiagnosticsAcceptanceProbe.waitForFile(missing, timeout: .zero, stage: "the Guest to unlock")
            XCTFail("A missing result must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("the Guest to unlock"))
        }
    }
    #endif

    #if RIFTVM_ACCEPTANCE_HARNESS
    @MainActor
    func testProbeFocusLossIsNotReportedAsGuestTimeout() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try await OmarchyInputDiagnosticsAcceptanceProbe.waitForFile(missing, checkFocus: {
                throw OmarchyInputDiagnosticsAcceptanceProbe.ProbeError.focusLost
            })
            XCTFail("Lost focus must interrupt the probe")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("lost keyboard focus"))
            XCTAssertFalse(error.localizedDescription.contains("Timed out"))
        }
    }
    #endif

    func testAccessibilityRequestHasVisiblePendingState() {
        XCTAssertNotEqual(
            OmarchyKeyboardIntegrationState.requestingAccessibility,
            .accessibilityRequired
        )
        XCTAssertNotEqual(OmarchyKeyboardIntegrationState.requestingAccessibility, .enabled)
    }

    #if RIFTVM_ACCEPTANCE_HARNESS
    func testInputDiagnosticsProbeCapturesHyprlandBindingAndDeviceState() {
        let script = OmarchyInputDiagnosticsAcceptanceProbe.probeScript(
            resultPath: "/mnt/riftvm-shared/result.txt"
        )

        XCTAssertTrue(script.contains("hyprctl binds -j"))
        XCTAssertTrue(script.contains("hyprctl devices -j"))
        XCTAssertTrue(script.contains("hyprctl activewindow -j"))
        XCTAssertTrue(script.contains("omarchy-shell lock status"))
        XCTAssertTrue(script.contains("pgrep -a omarchy-shell"))
        XCTAssertTrue(script.contains("result='/mnt/riftvm-shared/result.txt'"))
        XCTAssertTrue(script.contains("mv -f -- \"$partial\" \"$result\""))

        let watcher = OmarchyInputDiagnosticsAcceptanceProbe.lockWatcherScript(
            guestDirectory: "/mnt/riftvm-shared/probe"
        )
        XCTAssertTrue(watcher.contains("omarchy-shell lock isLocked"))
        XCTAssertTrue(watcher.contains("touch \"$d/locked\""))
        XCTAssertTrue(watcher.contains("touch \"$d/unlocked\""))
    }
    #endif

    #if RIFTVM_ACCEPTANCE_HARNESS
    func testLockWatcherSeparatesChordRecognitionFromOmarchyLockAction() {
        let script = OmarchyInputDiagnosticsAcceptanceProbe.lockWatcherScript(
            guestDirectory: "/mnt/riftvm-shared/probe"
        )
        XCTAssertTrue(script.contains("command -v omarchy-shell"))
        XCTAssertTrue(script.contains("OMARCHY_SHELL_IPC_TIMEOUT=0.5s"))
        XCTAssertTrue(script.contains("[[ $state == true || $state == false ]]"))
        XCTAssertFalse(script.contains("hyprlock"))
    }
    #endif

    #if RIFTVM_ACCEPTANCE_HARNESS
    func testLockWatcherStopsWhenHostCancelsBeforeReady() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let query = root.appending(path: "omarchy-shell")
        try Data("#!/bin/bash\ntouch '\(root.path)/unexpected-query'\n".utf8).write(to: query)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: query.path)
        try Data().write(to: root.appending(path: "cancel"))
        let script = root.appending(path: "watch-lock.sh")
        try Data(OmarchyInputDiagnosticsAcceptanceProbe.lockWatcherScript(guestDirectory: root.path).utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [script.path]
        process.environment = ["PATH": "\(root.path):/usr/bin:/bin"]
        let finished = expectation(description: "Cancelled watcher exits")
        process.terminationHandler = { _ in finished.fulfill() }
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        wait(for: [finished], timeout: 3)
        guard !process.isRunning else { return }
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "unexpected-query").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appending(path: "ready").path))
    }
    #endif

    #if RIFTVM_ACCEPTANCE_HARNESS
    @MainActor
    func testClipboardProbeWaitsForGuestScriptAndMatchingPasteboardPayloads() {
        let script = OmarchyClipboardAcceptanceProbe.probeScript(
            guestDirectory: "/mnt/riftvm-shared/probe"
        )

        XCTAssertTrue(script.contains("touch \"$d/script-ready\""))
        XCTAssertTrue(script.contains(
            "copy_until_matches \"$d/host-text-input\" \"$d/host-text-result\" --type 'text/plain;charset=utf-8' --no-newline"
        ))
        XCTAssertTrue(script.contains("cat \"$d/guest-text-input\" | /usr/bin/wl-copy --foreground --type 'text/plain;charset=utf-8'"))
        XCTAssertTrue(script.contains("cat \"$d/guest-image-input\" | /usr/bin/wl-copy --foreground --type image/png"))
        XCTAssertFalse(script.contains("native-wayland-result"))
        XCTAssertTrue(script.contains("copy_until_matches \"$d/host-image-input\""))
        XCTAssertTrue(script.contains("cmp -s \"$expected\" \"$local_part\""))
        XCTAssertTrue(script.contains("${XDG_RUNTIME_DIR:-/tmp}/riftvm-clipboard-probe.$$.part"))
        XCTAssertTrue(script.contains("guest-clipboard-types"))
    }
    #endif

    func testAcceptanceUnlockCredentialRequiresAcceptanceMode() {
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: "123456"
        ]))
        XCTAssertEqual(OmarchyAcceptanceUnlockCredential(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: "123456"
        ])?.password, "123456")
    }

    func testOwnerSetupBuildsOnePasswordRequestAndClearsSecrets() throws {
        var form = OmarchyOwnerSetupForm()
        form.password = "temporary-密碼"
        form.passwordConfirmation = form.password
        form.fullName = "Omarchy Owner"
        form.emailAddress = "owner@example.com"
        form.timezone = "America/Los_Angeles"

        let request = try form.validatedRequest()
        XCTAssertEqual(request.username, "omarchy")
        XCTAssertEqual(request.password, "temporary-密碼")
        XCTAssertEqual(request.keyboard, "us")
        XCTAssertEqual(request.timezone, "America/Los_Angeles")

        form.clearSecrets()
        XCTAssertTrue(form.password.isEmpty)
        XCTAssertTrue(form.passwordConfirmation.isEmpty)
        XCTAssertEqual(form.username, "omarchy")
    }

    func testOwnerSetupRejectsMismatchReservedNamesAndUnsafeFields() {
        var form = OmarchyOwnerSetupForm()
        form.password = "temporary-password"
        form.passwordConfirmation = "different"
        XCTAssertThrowsError(try form.validatedRequest()) {
            XCTAssertEqual($0 as? OmarchyOwnerSetupForm.ValidationError, .passwordsDoNotMatch)
        }

        form.passwordConfirmation = form.password
        form.username = "root"
        XCTAssertThrowsError(try form.validatedRequest()) {
            XCTAssertEqual($0 as? OmarchyOwnerSetupForm.ValidationError, .invalidUsername)
        }

        form.username = "omarchy"
        form.hostname = "-invalid"
        XCTAssertThrowsError(try form.validatedRequest()) {
            XCTAssertEqual($0 as? OmarchyOwnerSetupForm.ValidationError, .invalidHostname)
        }

        form.hostname = "omarchy"
        form.fullName = "Injected\nName"
        XCTAssertThrowsError(try form.validatedRequest()) {
            XCTAssertEqual($0 as? OmarchyOwnerSetupForm.ValidationError, .invalidIdentity)
        }
    }

    func testOwnerSetupKeyboardCodesAreUniqueAndMatchFactoryChoices() {
        let layouts = OmarchyOwnerSetupForm.keyboardLayouts
        XCTAssertEqual(Set(layouts.map(\.label)).count, layouts.count)
        XCTAssertEqual(layouts.first?.code, "us")
        XCTAssertTrue(layouts.contains(where: { $0.code == "jp106" }))
        XCTAssertTrue(layouts.contains(where: { $0.code == "br-abnt2" }))
    }

    func testAcceptanceWorkspaceOverrideRequiresExplicitFlagAndTemporaryRoot() throws {
        let fallback = try OmarchyWorkspaceConfiguration.layout(environment: [:])
        XCTAssertTrue(fallback.applicationSupportRoot.path.hasSuffix("/RiftVM Omarchy"))

        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-omarchy-acceptance-test")
        let selected = try OmarchyWorkspaceConfiguration.layout(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: temporary.path,
        ])
        XCTAssertEqual(selected.applicationSupportRoot, temporary.standardizedFileURL)

        let privateTemporary = try OmarchyWorkspaceConfiguration.layout(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/tmp/riftvm-omarchy-acceptance-test",
        ])
        XCTAssertTrue(
            privateTemporary.applicationSupportRoot.path.hasSuffix("/tmp/riftvm-omarchy-acceptance-test")
        )

        let privateSpelling = try OmarchyWorkspaceConfiguration.layout(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/private/tmp/riftvm-omarchy-acceptance-test",
        ])
        XCTAssertEqual(
            privateSpelling.applicationSupportRoot.path,
            "/private/tmp/riftvm-omarchy-acceptance-test"
        )

        XCTAssertThrowsError(try OmarchyWorkspaceConfiguration.layout(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/Users/shared/not-temporary",
        ]))
        XCTAssertEqual(
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey,
            "RIFTVM_OMARCHY_ACCEPTANCE_UNLOCK_PASSWORD"
        )
        XCTAssertEqual(
            OmarchyWorkspaceConfiguration.acceptanceBootUnlockKey,
            "RIFTVM_OMARCHY_BOOT_UNLOCK_ACCEPTANCE"
        )
    }

    func testAutomaticOwnerPasswordRequiresValidTemporaryAcceptanceWorkspace() {
        let password = "temporary-密碼"
        XCTAssertNil(OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword(
            environment: [OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: password]
        ))
        XCTAssertNil(OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/Users/shared/not-temporary",
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: password,
        ]))
        XCTAssertEqual(OmarchyWorkspaceConfiguration.acceptanceOwnerProvisioningPassword(environment: [
            OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1",
            OmarchyWorkspaceConfiguration.acceptanceRootKey: "/tmp/riftvm-owner-acceptance",
            OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey: password,
        ]), OmarchyWorkspaceConfiguration.acceptanceHarnessIncluded ? password : nil)
    }

    func testDedicatedAppUsesOmarchyProductIdentity() throws {
        let profile = VMOmarchyProfile.production
        try profile.validate()
        XCTAssertEqual(profile.productID, "com.riftvm.app.omarchy")
    }

    func testMicrophonePermissionPolicyRequiresExplicitAuthorization() {
        XCTAssertEqual(
            OmarchyMicrophonePermissionPolicy.action(for: .authorized),
            .enable
        )
        XCTAssertEqual(
            OmarchyMicrophonePermissionPolicy.action(for: .notDetermined),
            .request
        )
        XCTAssertEqual(
            OmarchyMicrophonePermissionPolicy.action(for: .denied),
            .openSystemSettings
        )
        XCTAssertEqual(
            OmarchyMicrophonePermissionPolicy.action(for: .restricted),
            .openSystemSettings
        )
        XCTAssertEqual(
            OmarchyMicrophonePermissionPolicy.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }

    func testClipboardActivationRequiresConsentAndReadyAgentSession() {
        let capabilities = Set(["clipboard-agent-text-v1", "clipboard-agent-image-v1"])
        XCTAssertTrue(OmarchyClipboardActivationPolicy.shouldRun(
            enabled: true,
            capabilities: capabilities,
            desktopSessionActive: true,
            provisioningPending: false,
            probeOwnsTransport: false
        ))
        XCTAssertFalse(OmarchyClipboardActivationPolicy.shouldRun(
            enabled: false,
            capabilities: capabilities,
            desktopSessionActive: true,
            provisioningPending: false,
            probeOwnsTransport: false
        ))
        XCTAssertFalse(OmarchyClipboardActivationPolicy.shouldRun(
            enabled: true,
            capabilities: ["clipboard-agent-text-v1"],
            desktopSessionActive: true,
            provisioningPending: false,
            probeOwnsTransport: false
        ))
        XCTAssertFalse(OmarchyClipboardActivationPolicy.shouldRun(
            enabled: true,
            capabilities: capabilities,
            desktopSessionActive: false,
            provisioningPending: false,
            probeOwnsTransport: false
        ))
        XCTAssertFalse(OmarchyClipboardActivationPolicy.shouldRun(
            enabled: true,
            capabilities: capabilities,
            desktopSessionActive: true,
            provisioningPending: true,
            probeOwnsTransport: false
        ))
        XCTAssertFalse(OmarchyClipboardActivationPolicy.shouldRun(
            enabled: true,
            capabilities: capabilities,
            desktopSessionActive: true,
            provisioningPending: false,
            probeOwnsTransport: true
        ))
    }

    func testNotificationActivationRequiresConsentCapabilityAndActiveDesktop() {
        let capabilities = Set(["desktop-notifications-v1"])
        XCTAssertTrue(OmarchyNotificationActivationPolicy.shouldRun(
            enabled: true,
            capabilities: capabilities,
            desktopSessionActive: true,
            provisioningPending: false
        ))
        XCTAssertFalse(OmarchyNotificationActivationPolicy.shouldRun(
            enabled: false,
            capabilities: capabilities,
            desktopSessionActive: true,
            provisioningPending: false
        ))
        XCTAssertFalse(OmarchyNotificationActivationPolicy.shouldRun(
            enabled: true,
            capabilities: [],
            desktopSessionActive: true,
            provisioningPending: false
        ))
        XCTAssertFalse(OmarchyNotificationActivationPolicy.shouldRun(
            enabled: true,
            capabilities: capabilities,
            desktopSessionActive: false,
            provisioningPending: false
        ))
        XCTAssertFalse(OmarchyNotificationActivationPolicy.shouldRun(
            enabled: true,
            capabilities: capabilities,
            desktopSessionActive: true,
            provisioningPending: true
        ))
    }

    func testNotificationPermissionPolicyNeverEnablesDeniedAccess() {
        XCTAssertEqual(OmarchyNotificationPermissionPolicy.action(for: .authorized), .enable)
        XCTAssertEqual(OmarchyNotificationPermissionPolicy.action(for: .provisional), .enable)
        XCTAssertEqual(OmarchyNotificationPermissionPolicy.action(for: .notDetermined), .request)
        XCTAssertEqual(OmarchyNotificationPermissionPolicy.action(for: .denied), .openSystemSettings)
    }

    func testNotificationDeliveryEstablishesBaselineAndDeduplicates() {
        var state = OmarchyNotificationDeliveryState(bootID: "boot-a")
        XCTAssertEqual(state.pendingIDs(from: ["old-1", "old-2"]), [])
        XCTAssertEqual(state.pendingIDs(from: ["old-2", "new-1"]), ["new-1"])
        XCTAssertEqual(state.pendingIDs(from: ["new-1"]), [])
        state.complete("new-1", succeeded: true)
        XCTAssertEqual(state.pendingIDs(from: ["new-1"]), [])
    }

    func testFailedNotificationDeliveryCanRetry() {
        var state = OmarchyNotificationDeliveryState(bootID: "boot-a")
        XCTAssertEqual(state.pendingIDs(from: []), [])
        XCTAssertEqual(state.pendingIDs(from: ["new-1"]), ["new-1"])
        state.complete("new-1", succeeded: false)
        XCTAssertEqual(state.pendingIDs(from: ["new-1"]), ["new-1"])
    }

    func testReleaseInfoTemplateCarriesFactoryTrustAndSourceProvenance() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let template = testFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "RiftVM/RiftVM/Info.plist")
        let values = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: template), format: nil
            ) as? [String: Any]
        )
        let factoryPublicKey = try XCTUnwrap(values["RiftVMOmarchyFactoryPublicKeyBase64"] as? String)
        XCTAssertEqual(Data(base64Encoded: factoryPublicKey)?.count, 32)
        XCTAssertEqual(values["RiftVMSourceRevision"] as? String, "$(RIFTVM_SOURCE_REVISION)")
        XCTAssertEqual(values["RiftVMSourceTreeState"] as? String, "$(RIFTVM_SOURCE_TREE_STATE)")
        XCTAssertEqual(values["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        XCTAssertEqual(
            values["NSMicrophoneUsageDescription"] as? String,
            "RiftVM uses the Mac microphone only when you enable microphone sharing for a workspace."
        )
    }

    func testReleaseBuildDisablesCoverageInstrumentation() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appending(path: "RiftVM/RiftVM.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        let releaseSections = project.components(separatedBy: "/* Release */")
        XCTAssertGreaterThanOrEqual(releaseSections.count, 3)
        XCTAssertGreaterThanOrEqual(
            project.components(separatedBy: "CLANG_ENABLE_CODE_COVERAGE = NO;").count - 1,
            2
        )
        XCTAssertGreaterThanOrEqual(
            project.components(separatedBy: "ENABLE_CODE_COVERAGE = NO;").count - 1,
            2
        )

        let releaseScript = try String(
            contentsOf: repository.appending(path: "scripts/build-release.sh"),
            encoding: .utf8
        )
        XCTAssertTrue(releaseScript.contains("CLANG_ENABLE_CODE_COVERAGE=NO"))
        XCTAssertTrue(releaseScript.contains("ENABLE_CODE_COVERAGE=NO"))
        XCTAssertTrue(releaseScript.contains("__llvm_prf|__llvm_cov"))
    }

    func testStopRequestsGracefulStopAndWaitsForGuest() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.stopRequested), [.requestStop, .scheduleForceStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertFalse(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelForceStop])
        XCTAssertEqual(lifecycle.phase, .stopped)
    }

    func testRestartStartsNewSessionOnlyAfterGuestStops() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.restartRequested), [.requestStop, .scheduleForceStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertTrue(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelForceStop, .startNewSession])
        XCTAssertEqual(lifecycle.phase, .starting)
        XCTAssertFalse(lifecycle.restartAfterStop)
    }

    func testDuplicateLifecycleCommandsAreIgnored() {
        var lifecycle = OmarchyMachineLifecycle()

        XCTAssertEqual(lifecycle.handle(.stopRequested), [])
        XCTAssertEqual(lifecycle.handle(.restartRequested), [])
        XCTAssertEqual(lifecycle.handle(.startRequested), [])
        XCTAssertEqual(lifecycle.phase, .starting)
    }

    func testPauseAndResumeRequireCompletedMachineTransitions() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.pauseRequested), [.requestPause])
        XCTAssertEqual(lifecycle.phase, .pausing)
        XCTAssertEqual(lifecycle.handle(.pauseRequested), [])
        XCTAssertEqual(lifecycle.handle(.resumeRequested), [])

        XCTAssertEqual(lifecycle.handle(.machinePaused), [])
        XCTAssertEqual(lifecycle.phase, .paused)
        XCTAssertEqual(lifecycle.handle(.resumeRequested), [.requestResume])
        XCTAssertEqual(lifecycle.phase, .resuming)
        XCTAssertEqual(lifecycle.handle(.resumeRequested), [])

        XCTAssertEqual(lifecycle.handle(.machineStarted), [])
        XCTAssertEqual(lifecycle.phase, .running)
    }

    func testPausedMachineCanStopOrRestartWithoutResuming() {
        var stopping = runningLifecycle()
        _ = stopping.handle(.pauseRequested)
        _ = stopping.handle(.machinePaused)
        XCTAssertEqual(stopping.handle(.stopRequested), [.requestStop, .scheduleForceStop])
        XCTAssertEqual(stopping.phase, .stopping)

        var restarting = runningLifecycle()
        _ = restarting.handle(.pauseRequested)
        _ = restarting.handle(.machinePaused)
        XCTAssertEqual(restarting.handle(.restartRequested), [.requestStop, .scheduleForceStop])
        XCTAssertTrue(restarting.restartAfterStop)
    }

    func testFailureCancelsPendingRestartAndCanBeRetried() {
        var lifecycle = runningLifecycle()
        _ = lifecycle.handle(.restartRequested)

        XCTAssertEqual(lifecycle.handle(.machineFailed("disk unavailable")), [.cancelForceStop])
        XCTAssertEqual(lifecycle.phase, .failed("disk unavailable"))
        XCTAssertFalse(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.startRequested), [.startNewSession])
        XCTAssertEqual(lifecycle.phase, .starting)
    }

    func testGracefulStopTimeoutForcesStopOnlyWhileStopping() {
        var lifecycle = runningLifecycle()
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [])
        _ = lifecycle.handle(.stopRequested)
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [.forceStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelForceStop])
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [])
    }

    @MainActor
    func testAppTargetedCommandRoutesOnceAndIgnoresOrdinaryOrUnfocusedInput() throws {
        var focused = true
        var forwarded: [CGKeyCode] = []
        let bridge = OmarchyFocusedCommandBridge(
            focusProbe: { focused },
            stateChanged: { _ in },
            redirectedCommandChord: { code, _ in forwarded.append(code); return true }
        )
        func event(_ down: Bool, command: Bool = true, synthetic: Bool = false) throws -> NSEvent {
            let value = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down))
            value.flags = command ? .maskCommand : []
            if synthetic {
                value.setIntegerValueField(
                    .eventSourceUserData,
                    value: OmarchyFocusedCommandBridge.syntheticMarker
                )
            }
            return try XCTUnwrap(NSEvent(cgEvent: value))
        }
        XCTAssertNil(bridge.handleLocalEvent(try event(true)))
        XCTAssertNil(bridge.handleLocalEvent(try event(false)))
        XCTAssertEqual(forwarded, [36])
        XCTAssertNotNil(bridge.handleLocalEvent(try event(true, command: false)))
        XCTAssertNotNil(bridge.handleLocalEvent(try event(true, synthetic: true)))
        focused = false
        XCTAssertNotNil(bridge.handleLocalEvent(try event(true)))
        XCTAssertEqual(forwarded, [36])
        bridge.stop()
    }

    func testDesktopInputPolicyUsesOnlyAgentAfterDesktopReadiness() {
        func status(
            capabilities: Set<String> = ["input-uinput-v1", "desktop-input-v1"],
            active: Bool = true,
            provisioning: Bool = false
        ) -> VMOmarchyGuestStatus {
            VMOmarchyGuestStatus(
                agentVersion: "test", hostName: "omarchy", addresses: [],
                capabilities: capabilities, desktopSessionActive: active,
                provisioningPending: provisioning
            )
        }

        XCTAssertTrue(OmarchyDesktopInputPolicy.usesGuestAgent(status: status()))
        XCTAssertFalse(OmarchyDesktopInputPolicy.usesGuestAgent(status: status(active: false)))
        XCTAssertFalse(OmarchyDesktopInputPolicy.usesGuestAgent(status: status(provisioning: true)))
        XCTAssertFalse(OmarchyDesktopInputPolicy.usesGuestAgent(
            status: status(capabilities: ["input-uinput-v1"])
        ))
    }

    @MainActor
    func testDesktopUinputForwardsDownRepeatUpWithoutNativeDuplication() throws {
        let view = OmarchyVirtualMachineInputView()
        var batches: [[VMGuestAgentInputEvent]] = []
        view.setGuestInputEventHandler { batches.append($0) }
        func event(_ type: NSEvent.EventType, repeat isRepeat: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: isRepeat, keyCode: 0
            ))
        }

        view.keyDown(with: try event(.keyDown))
        view.keyDown(with: try event(.keyDown, repeat: true))
        view.keyUp(with: try event(.keyUp))
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0], VMGuestAgentInputBatch.key(code: 30, pressed: true).events)
        XCTAssertEqual(batches[1],
            VMGuestAgentInputBatch.key(code: 30, pressed: false).events
            + VMGuestAgentInputBatch.key(code: 30, pressed: true).events
        )
        XCTAssertEqual(batches[2], VMGuestAgentInputBatch.key(code: 30, pressed: false).events)
    }

    @MainActor
    func testHostSleepReleasesHeldGuestKeysAndDetachingRemovesObserver() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = OmarchyVirtualMachineInputView()
        window.contentView = view
        var batches: [[VMGuestAgentInputEvent]] = []
        view.setGuestInputEventHandler { batches.append($0) }
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        view.keyDown(with: down)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(batches.last, VMGuestAgentInputBatch.key(code: 30, pressed: false).events)
        window.contentView = nil
        batches.removeAll()
        view.keyDown(with: down)
        let beforeNotification = batches
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(batches, beforeNotification)
        view.setGuestInputEventHandler(nil)
    }

    @MainActor
    func testDisablingDesktopUinputReleasesHeldKeys() throws {
        let view = OmarchyVirtualMachineInputView()
        var batches: [[VMGuestAgentInputEvent]] = []
        view.setGuestInputEventHandler { batches.append($0) }
        let down = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
        ))
        view.keyDown(with: down)
        view.setGuestInputEventHandler(nil)
        XCTAssertEqual(batches.last, VMGuestAgentInputBatch.key(code: 30, pressed: false).events)
    }

    @MainActor
    func testDesktopUinputDoesNotDuplicateCommandModifierOwnedByShortcutBridge() throws {
        let view = OmarchyVirtualMachineInputView()
        var batches: [[VMGuestAgentInputEvent]] = []
        view.setGuestInputEventHandler { batches.append($0) }
        for (keyCode, flags) in [(UInt16(55), NSEvent.ModifierFlags.command), (55, [])] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "",
                charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
            ))
            view.flagsChanged(with: event)
        }
        XCTAssertTrue(batches.isEmpty)
    }

    func testCommandModifierIsAlwaysOwnedByShortcutBridge() {
        XCTAssertTrue(OmarchyCommandCapturePolicy.ownsCommandModifier(keyCode: 54))
        XCTAssertTrue(OmarchyCommandCapturePolicy.ownsCommandModifier(keyCode: 55))
        XCTAssertFalse(OmarchyCommandCapturePolicy.ownsCommandModifier(keyCode: 56))
    }

    @MainActor
    func testDirectViewCommandDeliveryRoutesBalancedChordWithoutLocalMonitor() throws {
        var forwarded: [CGKeyCode] = []
        let bridge = OmarchyFocusedCommandBridge(
            focusProbe: { true },
            stateChanged: { _ in },
            redirectedCommandChord: { code, _ in forwarded.append(code); return true }
        )
        let view = OmarchyVirtualMachineInputView()
        view.commandEventHandler = { bridge.handleLocalEvent($0) == nil }
        func event(_ down: Bool) throws -> NSEvent {
            let value = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down))
            value.flags = .maskCommand
            return try XCTUnwrap(NSEvent(cgEvent: value))
        }
        view.keyDown(with: try event(true))
        view.keyUp(with: try event(false))
        XCTAssertEqual(forwarded, [36])
        XCTAssertTrue(view.performKeyEquivalent(with: try event(true)))
        view.keyUp(with: try event(false))
        XCTAssertEqual(forwarded, [36, 36])
        bridge.stop()
    }

    @MainActor
    func testCapturedKeyReleaseKeepsOwnershipAfterCommandAndFocusRelease() throws {
        var focused = true
        let previousWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        previousWindow.isReleasedWhenClosed = false
        defer { previousWindow.close() }
        var forwarded = 0
        let bridge = OmarchyFocusedCommandBridge(
            focusProbe: { focused },
            stateChanged: { _ in },
            redirectedCommandChord: { _, _ in forwarded += 1; return true }
        )
        func event(_ down: Bool, command: Bool) throws -> NSEvent {
            let value = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down))
            value.flags = command ? .maskCommand : []
            return try XCTUnwrap(NSEvent(cgEvent: value))
        }
        XCTAssertNil(bridge.handleLocalEvent(try event(true, command: true)))
        focused = false
        let releaseInPreviousWindow = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: previousWindow.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
        XCTAssertNil(bridge.handleLocalEvent(releaseInPreviousWindow))
        XCTAssertNotNil(bridge.handleLocalEvent(try event(false, command: false)))
        focused = true
        XCTAssertNil(bridge.handleLocalEvent(try event(true, command: true)))
        XCTAssertNil(bridge.handleLocalEvent(try event(false, command: false)))
        XCTAssertEqual(forwarded, 2)
        bridge.stop()
    }

    func testCommandChordRedirectsOnlyWhileOmarchyIsFocused() {
        XCTAssertTrue(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyDown, keyCode: 49, flags: [.maskCommand], focused: true, isSynthetic: false
        ))
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyDown, keyCode: 49, flags: [.maskCommand], focused: false, isSynthetic: false
        ))
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyDown, keyCode: 49, flags: [], focused: true, isSynthetic: false
        ))
    }

    func testSyntheticAndCommandModifierEventsNeverLoopThroughBridge() {
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyDown, keyCode: 49, flags: [.maskCommand], focused: true, isSynthetic: true
        ))
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .flagsChanged, keyCode: 55, flags: [.maskCommand], focused: true, isSynthetic: false
        ))
        XCTAssertFalse(OmarchyCommandCapturePolicy.shouldRedirect(
            type: .keyUp, keyCode: 55, flags: [.maskCommand], focused: true, isSynthetic: false
        ))
    }

    func testCommandSpaceCaptureRequiresOrderedDownAndUp() {
        var state = OmarchyCommandSpaceCaptureState()
        XCTAssertFalse(state.observe(type: .keyUp, keyCode: 49))
        XCTAssertFalse(state.observe(type: .keyDown, keyCode: 0))
        XCTAssertFalse(state.observe(type: .keyDown, keyCode: 49))
        XCTAssertTrue(state.observe(type: .keyUp, keyCode: 49))
        XCTAssertFalse(state.observe(type: .keyUp, keyCode: 49))
    }

    func testCommandSuperObservationIsBoundToRuntimeState() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-command-super-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        OmarchyAcceptanceObservationReporter.reportCommandSuperIfEnabled(
            layout: layout,
            applicationActive: true,
            virtualMachineWindowKey: true,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"],
            bundleInfo: ["RiftVMSourceRevision": "revision"]
        )
        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.commandSuperFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["sourceRevision"] as? String, "revision")
        XCTAssertEqual(json["eventTapEnabled"] as? Bool, true)
        XCTAssertEqual(json["commandSpaceKeyDownAndUpCaptured"] as? Bool, true)
        XCTAssertEqual(json["applicationActiveAfterCapture"] as? Bool, true)
        XCTAssertEqual(json["virtualMachineWindowKeyAfterCapture"] as? Bool, true)
    }

    func testFullScreenTransitionRequiresOrderedEnterAndExit() {
        var state = OmarchyFullScreenTransitionState()
        let entered = Date(timeIntervalSince1970: 10)
        let exited = Date(timeIntervalSince1970: 11)
        XCTAssertFalse(state.observeExited(at: exited))
        XCTAssertTrue(state.observeEntered(at: entered))
        XCTAssertFalse(state.observeEntered(at: entered))
        XCTAssertTrue(state.observeExited(at: exited))
        XCTAssertFalse(state.observeExited(at: exited))
        XCTAssertEqual(state.enteredAt, entered)
        XCTAssertEqual(state.exitedAt, exited)
    }

    func testLockAcceptanceCompletesOnlyAnObservedInteractiveCycle() {
        var state = OmarchyLockAcceptanceState()
        XCTAssertFalse(state.completeObservedCycle())
        XCTAssertTrue(state.begin())
        XCTAssertFalse(state.begin())
        XCTAssertTrue(state.completeObservedCycle())
        XCTAssertFalse(state.completeObservedCycle())
        XCTAssertEqual(state.phase, .complete)
    }

    func testAcceptanceUnlockCredentialIsScopedAndBounded() {
        let enabled = OmarchyWorkspaceConfiguration.acceptanceEnabledKey
        let password = OmarchyWorkspaceConfiguration.acceptanceUnlockPasswordKey
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [password: "test"]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [enabled: "1"]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [enabled: "1", password: ""]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [
            enabled: "1", password: String(repeating: "a", count: 129)
        ]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [enabled: "1", password: "line\nfeed"]))
        XCTAssertNil(OmarchyAcceptanceUnlockCredential(environment: [enabled: "1", password: "密碼"]))
        XCTAssertEqual(
            OmarchyAcceptanceUnlockCredential(environment: [enabled: "1", password: "test-123!"])?.password,
            "test-123!"
        )
    }

    func testGuestRestartAcceptanceUnlocksBeforeCompleting() {
        var state = OmarchyGuestRestartAcceptanceState()
        XCTAssertTrue(state.begin(previousBootID: "boot-before"))

        let before = VMOmarchyGuestStatus(
            agentVersion: "agent", bootID: "boot-before", hostName: "omarchy",
            addresses: [], capabilities: [], desktopSessionActive: true,
            provisioningPending: false
        )
        let lockedAfter = VMOmarchyGuestStatus(
            agentVersion: "agent", bootID: "boot-after", hostName: "omarchy",
            addresses: [], capabilities: [], desktopSessionActive: false,
            provisioningPending: false
        )
        let activeAfter = VMOmarchyGuestStatus(
            agentVersion: "agent", bootID: "boot-after", hostName: "omarchy",
            addresses: [], capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true,
            provisioningPending: false
        )
        XCTAssertEqual(state.observe(before), .none)
        XCTAssertEqual(state.observe(lockedAfter), .recoverInteractiveDesktop)
        XCTAssertEqual(state.observe(lockedAfter), .none)
        XCTAssertEqual(state.observe(activeAfter), .none)
        XCTAssertFalse(state.completeInteractiveProof(bootID: "wrong-boot"))
        XCTAssertTrue(state.completeInteractiveProof(bootID: "boot-after"))
        XCTAssertEqual(state.phase, .complete)
    }

    func testGuestRestartAcceptanceNeverTrustsStatusWithoutInteractiveProof() {
        var state = OmarchyGuestRestartAcceptanceState()
        XCTAssertTrue(state.begin(previousBootID: "boot-before"))
        let activeAfter = VMOmarchyGuestStatus(
            agentVersion: "agent", bootID: "boot-after", hostName: "omarchy",
            addresses: [], capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true,
            provisioningPending: false
        )
        XCTAssertEqual(state.observe(activeAfter), .recoverInteractiveDesktop)
        XCTAssertEqual(state.observe(activeAfter), .none)
        XCTAssertTrue(state.completeInteractiveProof(bootID: "boot-after"))
    }

    func testGuestRestartAcceptanceDoesNotTrustActiveFlagWithoutSessionAgent() {
        var state = OmarchyGuestRestartAcceptanceState()
        XCTAssertTrue(state.begin(previousBootID: "boot-before"))
        let falselyActiveAfter = VMOmarchyGuestStatus(
            agentVersion: "agent", bootID: "boot-after", hostName: "omarchy",
            addresses: [], capabilities: [], desktopSessionActive: true,
            provisioningPending: false
        )
        let interactiveAfter = VMOmarchyGuestStatus(
            agentVersion: "agent", bootID: "boot-after", hostName: "omarchy",
            addresses: [], capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true, provisioningPending: false
        )

        XCTAssertEqual(state.observe(falselyActiveAfter), .recoverInteractiveDesktop)
        XCTAssertEqual(state.observe(falselyActiveAfter), .none)
        XCTAssertEqual(state.observe(interactiveAfter), .none)
        XCTAssertTrue(state.completeInteractiveProof(bootID: "boot-after"))
    }

    func testAgentRestartRecoveryWaitsForTheInteractiveSessionAgent() {
        let baseline = VMOmarchyGuestStatus(
            agentVersion: "agent", agentInstanceID: "instance-before", bootID: "boot",
            hostName: "omarchy", addresses: [],
            capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true, provisioningPending: false
        )
        let systemAgentOnly = VMOmarchyGuestStatus(
            agentVersion: "agent", agentInstanceID: "instance-after", bootID: "boot",
            hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: true, provisioningPending: false
        )
        let recovered = VMOmarchyGuestStatus(
            agentVersion: "agent", agentInstanceID: "instance-after", bootID: "boot",
            hostName: "omarchy", addresses: [],
            capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true, provisioningPending: false
        )

        XCTAssertFalse(OmarchyAgentRestartRecoveryReadiness.isReady(
            baseline: baseline, recovered: systemAgentOnly
        ))
        XCTAssertTrue(OmarchyAgentRestartRecoveryReadiness.isReady(
            baseline: baseline, recovered: recovered
        ))
    }

    func testIntegrationObservationRecognizesAuthenticatedClipboardCapabilities() throws {
        let status = VMOmarchyGuestStatus(
            agentVersion: "agent", hostName: "omarchy", addresses: ["192.0.2.1"],
            capabilities: [
                "shared-folders-v1", "clipboard-agent-text-v1",
                "clipboard-agent-image-v1", "dynamic-display-v1",
            ],
            desktopSessionActive: true, provisioningPending: false
        )
        let observation = OmarchyAcceptanceObservationReporter.makeObservation(
            status: status,
            requiredCapabilities: [],
            workspaceCreatedAt: Date(timeIntervalSince1970: 1),
            factoryImageVersion: "factory",
            sourceRevision: "revision",
            sharedFolderRoundTrip: nil,
            clipboardRoundTrip: nil,
            dynamicDisplayRoundTrip: nil,
            observedAt: Date(timeIntervalSince1970: 2)
        )
        XCTAssertTrue(observation.clipboardTextCapabilityAdvertised)
        XCTAssertTrue(observation.clipboardImageCapabilityAdvertised)
    }

    func testFullScreenObservationIsBoundToRuntimeState() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-full-screen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        OmarchyAcceptanceObservationReporter.reportFullScreenIfEnabled(
            layout: layout,
            enteredAt: Date(timeIntervalSince1970: 10),
            exitedAt: Date(timeIntervalSince1970: 11),
            applicationActive: true,
            virtualMachineWindowKey: true,
            virtualMachineViewFocused: true,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"],
            bundleInfo: ["RiftVMSourceRevision": "revision"]
        )
        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.fullScreenFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["sourceRevision"] as? String, "revision")
        XCTAssertEqual(json["enteredAndExitedFullScreen"] as? Bool, true)
        XCTAssertEqual(json["applicationActiveAfterExit"] as? Bool, true)
        XCTAssertEqual(json["virtualMachineWindowKeyAfterExit"] as? Bool, true)
        XCTAssertEqual(json["virtualMachineViewFocusedAfterExit"] as? Bool, true)
    }

    func testDesktopNotificationObservationRecordsAcceptedGuestDelivery() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-notification-observation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let notification = try JSONDecoder().decode(
            VMOmarchyDesktopNotification.self,
            from: Data(#"{"id":"guest-id","app":"Terminal","title":"acceptance-title","body":"body","urgency":1,"timestamp":1700000000}"#.utf8)
        )

        OmarchyAcceptanceObservationReporter.reportDesktopNotificationIfEnabled(
            notification,
            guestBootID: "boot-id",
            layout: layout,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"],
            bundleInfo: ["RiftVMSourceRevision": "source-revision"],
            observedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.desktopNotificationFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["sourceRevision"] as? String, "source-revision")
        XCTAssertEqual(json["guestBootID"] as? String, "boot-id")
        XCTAssertEqual(json["guestNotificationID"] as? String, "guest-id")
        XCTAssertEqual(json["notificationTitle"] as? String, "acceptance-title")
        XCTAssertEqual(json["macOSRequestAccepted"] as? Bool, true)
    }

    func testSoakHeartbeatRecordsAuthenticatedGuestContinuity() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-soak-heartbeat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let status = VMOmarchyGuestStatus(
            agentVersion: "agent", agentInstanceID: "instance", bootID: "boot",
            uptimeSeconds: 1234, hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: true, provisioningPending: false
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: status,
            layout: layout,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"],
            bundleInfo: ["RiftVMSourceRevision": "revision"]
        )
        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.soakHeartbeatFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["sourceRevision"] as? String, "revision")
        XCTAssertEqual(json["guestAgentVersion"] as? String, "agent")
        XCTAssertEqual(json["agentInstanceID"] as? String, "instance")
        XCTAssertEqual(json["bootID"] as? String, "boot")
        XCTAssertEqual(json["uptimeSeconds"] as? Int, 1234)
        XCTAssertEqual(json["desktopSessionActive"] as? Bool, true)
        XCTAssertEqual(json["provisioningPending"] as? Bool, false)
    }

    func testIntegrationRequiresDesktopProvisioningAndEverySignedCapability() {
        let required = VMOmarchyProfile.production.requiredGuestCapabilities
        let readyStatus = VMOmarchyGuestStatus(
            agentVersion: "test",
            hostName: "omarchy",
            addresses: ["192.0.2.10"],
            capabilities: Set(required),
            desktopSessionActive: true,
            provisioningPending: false
        )
        XCTAssertTrue(VMOmarchyIntegrationAssessment.evaluate(
            status: readyStatus,
            requiredCapabilities: required
        ).isReady)

        let pending = VMOmarchyGuestStatus(
            agentVersion: "test",
            hostName: "omarchy",
            addresses: [],
            capabilities: Set(required.dropLast()),
            desktopSessionActive: true,
            provisioningPending: true
        )
        let assessment = VMOmarchyIntegrationAssessment.evaluate(
            status: pending,
            requiredCapabilities: required
        )
        XCTAssertFalse(assessment.isReady)
        XCTAssertTrue(assessment.provisioningPending)
        XCTAssertEqual(assessment.missingCapabilities, [required.last!])
    }

    func testAcceptanceObservationRecordsOnlyObservedIntegrationFacts() throws {
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let status = VMOmarchyGuestStatus(
            agentVersion: "agent-commit",
            omarchyRevision: "omarchy-commit",
            hostName: "omarchy",
            addresses: ["2001:db8::2", "192.0.2.2"],
            capabilities: [
                "agent-restart-v1", "desktop-input-v1", "dynamic-display-v1", "shutdown-v1",
                "shared-folders-v1", "clipboard-text-v1", "clipboard-image-v1",
            ],
            desktopSessionActive: true,
            provisioningPending: false
        )
        let observation = OmarchyAcceptanceObservationReporter.makeObservation(
            status: status,
            requiredCapabilities: VMOmarchyProfile.production.requiredGuestCapabilities,
            workspaceCreatedAt: observedAt.addingTimeInterval(-60),
            factoryImageVersion: "factory-version",
            sourceRevision: "source-commit",
            sharedFolderRoundTrip: VMOmarchySharedFolderRoundTrip(
                observedAt: observedAt,
                hostToGuestSHA256: String(repeating: "a", count: 64),
                guestToHostSHA256: String(repeating: "b", count: 64),
                fileImportObservedAt: observedAt,
                importedFileSHA256: String(repeating: "c", count: 64)
            ),
            clipboardRoundTrip: OmarchyClipboardRoundTrip(
                observedAt: observedAt,
                advertisedCapabilities: [
                    "clipboard-agent-text-v1", "clipboard-agent-image-v1",
                ],
                hostToGuestTextSHA256: String(repeating: "c", count: 64),
                guestToHostTextSHA256: String(repeating: "d", count: 64),
                hostToGuestImageSHA256: String(repeating: "e", count: 64),
                guestToHostImageSHA256: String(repeating: "f", count: 64)
            ),
            dynamicDisplayRoundTrip: OmarchyDynamicDisplayRoundTrip(
                observedAt: observedAt,
                guestBefore: .init(width: 1920, height: 1200),
                guestAfter: .init(width: 880, height: 560),
                hostViewAfter: .init(width: 880, height: 560)
            ),
            observedAt: observedAt
        )

        XCTAssertEqual(observation.schemaVersion, 5)
        XCTAssertEqual(observation.observedAt, observedAt)
        XCTAssertEqual(observation.sourceRevision, "source-commit")
        XCTAssertEqual(observation.factoryImageVersion, "factory-version")
        XCTAssertEqual(observation.workspaceCreatedAt, observedAt.addingTimeInterval(-60))
        XCTAssertEqual(observation.guestAgentVersion, "agent-commit")
        XCTAssertEqual(observation.omarchyRevision, "omarchy-commit")
        XCTAssertEqual(observation.guestAddresses, ["192.0.2.2", "2001:db8::2"])
        XCTAssertTrue(observation.desktopSessionActive)
        XCTAssertFalse(observation.provisioningPending)
        XCTAssertTrue(observation.sharedFolderCapabilityAdvertised)
        XCTAssertTrue(observation.clipboardTextCapabilityAdvertised)
        XCTAssertTrue(observation.clipboardImageCapabilityAdvertised)
        XCTAssertTrue(observation.dynamicDisplayCapabilityAdvertised)
        XCTAssertTrue(observation.sharedFolderRoundTripPassed)
        XCTAssertTrue(observation.fileImportPassed)
        XCTAssertEqual(observation.fileImportObservedAt, observedAt)
        XCTAssertEqual(observation.importedFileSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(observation.sharedFolderRoundTripObservedAt, observedAt)
        XCTAssertEqual(observation.hostToGuestSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(observation.guestToHostSHA256, String(repeating: "b", count: 64))
        XCTAssertTrue(observation.clipboardRoundTripPassed)
        XCTAssertEqual(observation.clipboardRoundTripObservedAt, observedAt)
        XCTAssertEqual(observation.hostToGuestTextSHA256, String(repeating: "c", count: 64))
        XCTAssertEqual(observation.guestToHostTextSHA256, String(repeating: "d", count: 64))
        XCTAssertEqual(observation.hostToGuestImageSHA256, String(repeating: "e", count: 64))
        XCTAssertEqual(observation.guestToHostImageSHA256, String(repeating: "f", count: 64))
        XCTAssertTrue(observation.dynamicDisplayRoundTripPassed)
        XCTAssertEqual(observation.dynamicDisplayRoundTripObservedAt, observedAt)
        XCTAssertEqual(observation.guestDisplayBefore, .init(width: 1920, height: 1200))
        XCTAssertEqual(observation.guestDisplayAfter, .init(width: 880, height: 560))
        XCTAssertEqual(observation.hostViewAfter, .init(width: 880, height: 560))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertNoThrow(try decoder.decode(
            OmarchyIntegrationObservation.self, from: observation.encoded()
        ))
    }

    func testAcceptanceLifecyclePreservesLockedThenUnlockedEvidence() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-omarchy-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let environment = [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"]
        let provisioningAt = Date(timeIntervalSince1970: 1_699_999_990)
        let lockedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let unlockedAt = lockedAt.addingTimeInterval(10)
        let pauseRequestedAt = unlockedAt.addingTimeInterval(10)
        let pausedAt = pauseRequestedAt.addingTimeInterval(1)
        let resumedAt = pausedAt.addingTimeInterval(2)
        let recoveredAt = resumedAt.addingTimeInterval(3)
        let agentRestartAt = recoveredAt.addingTimeInterval(1)
        let agentDisconnectedAt = agentRestartAt.addingTimeInterval(1)
        let agentRecoveredAt = agentDisconnectedAt.addingTimeInterval(3)
        let guestRestartAt = agentRecoveredAt.addingTimeInterval(1)
        let guestDisconnectedAt = guestRestartAt.addingTimeInterval(1)
        let guestRecoveredAt = guestDisconnectedAt.addingTimeInterval(8)
        let hostSleepAt = guestRecoveredAt.addingTimeInterval(10)
        let hostWakeAt = hostSleepAt.addingTimeInterval(4)
        let hostRecoveredAt = hostWakeAt.addingTimeInterval(3)
        let provisioning = VMOmarchyGuestStatus(
            agentVersion: "agent-commit",
            hostName: "omarchy",
            addresses: [],
            capabilities: [],
            desktopSessionActive: false,
            provisioningPending: true
        )
        let locked = VMOmarchyGuestStatus(
            agentVersion: "agent-commit",
            hostName: "omarchy",
            addresses: [],
            capabilities: [],
            desktopSessionActive: false,
            provisioningPending: false
        )
        let unlocked = VMOmarchyGuestStatus(
            agentVersion: "agent-commit",
            agentInstanceID: "instance-before",
            bootID: "boot-before",
            hostName: "omarchy",
            addresses: [],
            capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true,
            provisioningPending: false
        )
        let agentRecovered = VMOmarchyGuestStatus(
            agentVersion: "agent-commit", agentInstanceID: "instance-after",
            bootID: "boot-before", hostName: "omarchy", addresses: [],
            capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true, provisioningPending: false
        )
        let guestRecovered = VMOmarchyGuestStatus(
            agentVersion: "agent-commit", agentInstanceID: "instance-after-boot",
            bootID: "boot-after", hostName: "omarchy", addresses: [],
            capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true, provisioningPending: false
        )

        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: provisioning,
            layout: layout,
            environment: environment,
            observedAt: provisioningAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: locked, layout: layout, environment: environment, observedAt: lockedAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: unlocked, layout: layout, environment: environment, observedAt: unlockedAt
        )
        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
            .pauseRequested, layout: layout, environment: environment, observedAt: pauseRequestedAt
        )
        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
            .paused, layout: layout, environment: environment, observedAt: pausedAt
        )
        OmarchyAcceptanceObservationReporter.reportVirtualMachineEventIfEnabled(
            .resumed, layout: layout, environment: environment, observedAt: resumedAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: unlocked, layout: layout, environment: environment, observedAt: recoveredAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .agentRestartRequested(unlocked), layout: layout, environment: environment,
            observedAt: agentRestartAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .disconnectedAfterAgentRestart, layout: layout, environment: environment,
            observedAt: agentDisconnectedAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: agentRecovered, layout: layout, environment: environment,
            observedAt: agentRecoveredAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .guestRestartRequested(agentRecovered), layout: layout, environment: environment,
            observedAt: guestRestartAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .disconnectedAfterGuestRestart, layout: layout, environment: environment,
            observedAt: guestDisconnectedAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: guestRecovered, layout: layout, environment: environment,
            observedAt: guestRecoveredAt
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .guestInteractiveAfterRestart(guestRecovered), layout: layout,
            environment: environment, observedAt: guestRecoveredAt
        )
        OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
            .willSleep, layout: layout, environment: environment, observedAt: hostSleepAt
        )
        OmarchyAcceptanceObservationReporter.reportHostPowerEventIfEnabled(
            .didWake, layout: layout, environment: environment, observedAt: hostWakeAt
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: guestRecovered, layout: layout, environment: environment, observedAt: hostRecoveredAt
        )
        OmarchyAcceptanceObservationReporter.reportInteractiveAfterHostWakeIfEnabled(
            status: guestRecovered, layout: layout, environment: environment,
            observedAt: hostRecoveredAt
        )

        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.lifecycleFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 6)
        XCTAssertEqual(json["sourceRevision"] as? String, "")
        XCTAssertNotNil(json["firstProvisioningPendingObservedAt"])
        XCTAssertNotNil(json["firstLockedObservedAt"])
        XCTAssertNotNil(json["firstActiveObservedAt"])
        XCTAssertNotNil(json["firstActiveAfterLockedObservedAt"])
        XCTAssertNotNil(json["firstPauseRequestedAt"])
        XCTAssertNotNil(json["firstPausedAt"])
        XCTAssertNotNil(json["firstResumedAt"])
        XCTAssertNotNil(json["firstActiveAfterResumeObservedAt"])
        XCTAssertNotNil(json["firstAgentRestartRequestedAt"])
        XCTAssertNotNil(json["firstAgentDisconnectedAfterRestartAt"])
        XCTAssertNotNil(json["firstAgentRecoveredAt"])
        XCTAssertEqual(json["agentBootIDBeforeRestart"] as? String, "boot-before")
        XCTAssertEqual(json["agentBootIDAfterRestart"] as? String, "boot-before")
        XCTAssertEqual(json["agentInstanceIDBeforeRestart"] as? String, "instance-before")
        XCTAssertEqual(json["agentInstanceIDAfterRestart"] as? String, "instance-after")
        XCTAssertNotNil(json["firstGuestRestartRequestedAt"])
        XCTAssertNotNil(json["firstGuestDisconnectedAfterRestartAt"])
        XCTAssertNotNil(json["firstGuestRecoveredAt"])
        XCTAssertEqual(json["guestBootIDBeforeRestart"] as? String, "boot-before")
        XCTAssertEqual(json["guestBootIDAfterRestart"] as? String, "boot-after")
        XCTAssertNotNil(json["firstHostSleepObservedAt"])
        XCTAssertNotNil(json["firstHostWakeObservedAt"])
        XCTAssertNotNil(json["firstActiveAfterHostWakeObservedAt"])
        XCTAssertEqual(json["lastDesktopSessionActive"] as? Bool, true)
        XCTAssertEqual(json["lastProvisioningPending"] as? Bool, false)
        XCTAssertEqual(json["guestAgentVersion"] as? String, "agent-commit")
    }

    func testAcceptanceLifecycleDoesNotRecordGuestRecoveryBeforeSessionAgentIsReady() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-omarchy-false-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let environment = [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"]
        let before = VMOmarchyGuestStatus(
            agentVersion: "agent", agentInstanceID: "instance-before", bootID: "boot-before",
            hostName: "omarchy", addresses: [],
            capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true, provisioningPending: false
        )
        let activeFlagOnly = VMOmarchyGuestStatus(
            agentVersion: "agent", agentInstanceID: "instance-after", bootID: "boot-after",
            hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: true, provisioningPending: false
        )
        let interactive = VMOmarchyGuestStatus(
            agentVersion: "agent", agentInstanceID: "instance-after", bootID: "boot-after",
            hostName: "omarchy", addresses: [],
            capabilities: OmarchyInteractiveDesktopReadiness.requiredSessionCapabilities,
            desktopSessionActive: true, provisioningPending: false
        )

        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: before, layout: layout, environment: environment
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .guestRestartRequested(before), layout: layout, environment: environment
        )
        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .disconnectedAfterGuestRestart, layout: layout, environment: environment
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: activeFlagOnly, layout: layout, environment: environment
        )

        let file = layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.lifecycleFileName
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertNil(json["firstGuestRecoveredAt"])
        XCTAssertNil(json["guestBootIDAfterRestart"])

        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: interactive, layout: layout, environment: environment
        )
        json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertNil(json["firstGuestRecoveredAt"])
        XCTAssertNil(json["guestBootIDAfterRestart"])

        OmarchyAcceptanceObservationReporter.reportRecoveryEventIfEnabled(
            .guestInteractiveAfterRestart(interactive), layout: layout,
            environment: environment
        )
        json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        XCTAssertNotNil(json["firstGuestRecoveredAt"])
        XCTAssertEqual(json["guestBootIDAfterRestart"] as? String, "boot-after")
    }

    func testExplicitLockCycleSurvivesCoalescedStatusUpdates() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-omarchy-lock-cycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let environment = [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"]
        let active = VMOmarchyGuestStatus(
            agentVersion: "agent", hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: true, provisioningPending: false
        )
        let activeAt = Date(timeIntervalSince1970: 1_700_000_010)
        let lockedAt = activeAt.addingTimeInterval(2)
        let recoveredAt = lockedAt.addingTimeInterval(8)
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: active, layout: layout, environment: environment, observedAt: activeAt
        )
        OmarchyAcceptanceObservationReporter.reportLockCycleIfEnabled(
            layout: layout, lockedAt: lockedAt, activeAt: recoveredAt,
            environment: environment
        )

        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.lifecycleFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["firstLockedObservedAt"])
        XCTAssertNotNil(json["firstActiveAfterLockedObservedAt"])
        XCTAssertEqual(json["lastDesktopSessionActive"] as? Bool, true)
    }

    func testAcceptanceLifecycleReplacesLegacySchemaBeforeRecordingEvents() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-omarchy-lifecycle-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: layout.diagnostics, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":3,"guestAgentVersion":"legacy"}"#.utf8).write(
            to: layout.diagnostics.appending(
                path: OmarchyAcceptanceObservationReporter.lifecycleFileName
            )
        )
        let status = VMOmarchyGuestStatus(
            agentVersion: "current",
            hostName: "omarchy",
            addresses: [],
            capabilities: [],
            desktopSessionActive: false,
            provisioningPending: true
        )

        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: status,
            layout: layout,
            environment: [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"]
        )

        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.lifecycleFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 6)
        XCTAssertEqual(json["sourceRevision"] as? String, "")
        XCTAssertEqual(json["guestAgentVersion"] as? String, "current")
        XCTAssertNotNil(json["firstProvisioningPendingObservedAt"])
    }

    func testAcceptanceLifecycleStartsFreshWhenHostRevisionChanges() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "riftvm-omarchy-lifecycle-revision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        let environment = [OmarchyWorkspaceConfiguration.acceptanceEnabledKey: "1"]
        let status = VMOmarchyGuestStatus(
            agentVersion: "agent", hostName: "omarchy", addresses: [], capabilities: [],
            desktopSessionActive: false, provisioningPending: true
        )

        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: status,
            layout: layout,
            environment: environment,
            bundleInfo: ["RiftVMSourceRevision": "old-revision"]
        )
        OmarchyAcceptanceObservationReporter.reportLifecycleIfEnabled(
            status: status,
            layout: layout,
            environment: environment,
            bundleInfo: ["RiftVMSourceRevision": "new-revision"]
        )

        let data = try Data(contentsOf: layout.diagnostics.appending(
            path: OmarchyAcceptanceObservationReporter.lifecycleFileName
        ))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 6)
        XCTAssertEqual(json["sourceRevision"] as? String, "new-revision")
        XCTAssertEqual(json["guestAgentVersion"] as? String, "agent")
    }

    #if RIFTVM_ACCEPTANCE_HARNESS
    @MainActor
    func testDynamicDisplayProbeDecodesActiveHyprlandMonitor() throws {
        let data = Data(#"[{"disabled":true,"width":1,"height":1},{"disabled":false,"width":1440,"height":900}]"#.utf8)
        XCTAssertEqual(
            try OmarchyDynamicDisplayAcceptanceProbe.decodeDisplay(data),
            OmarchyDisplaySize(width: 1440, height: 900)
        )
        XCTAssertThrowsError(try OmarchyDynamicDisplayAcceptanceProbe.decodeDisplay(Data("[]".utf8)))
    }
    #endif

    private func runningLifecycle() -> OmarchyMachineLifecycle {
        var lifecycle = OmarchyMachineLifecycle()
        XCTAssertEqual(lifecycle.handle(.machineStarted), [])
        XCTAssertEqual(lifecycle.phase, .running)
        return lifecycle
    }

    @MainActor
    func testApplicationTerminationWaitsForGracefulGuestStop() {
        let machine = MockTerminableMachine(canRequestStop: true, canStop: true)
        var replies: [Bool] = []
        var timeout: DispatchWorkItem?
        let controller = OmarchyApplicationTerminationController(
            reply: { replies.append($0) },
            scheduleTimeout: { timeout = $0 }
        )
        controller.register(machine)

        XCTAssertEqual(controller.requestTermination(), .terminateLater)
        XCTAssertEqual(machine.requestStopCount, 1)
        XCTAssertEqual(machine.forceStopCount, 0)
        XCTAssertTrue(replies.isEmpty)
        XCTAssertNotNil(timeout)

        controller.machineDidStop(machine)
        XCTAssertEqual(replies, [true])
        XCTAssertTrue(timeout?.isCancelled == true)
    }

    @MainActor
    func testViewTeardownAndQuitShareOneShutdownTransaction() {
        let machine = MockTerminableMachine(canRequestStop: true, canStop: true)
        var replies: [Bool] = []
        let controller = OmarchyApplicationTerminationController(
            reply: { replies.append($0) }, scheduleTimeout: { _ in }
        )
        controller.register(machine)
        controller.stopForViewTeardown(machine)
        XCTAssertEqual(machine.requestStopCount, 1)

        XCTAssertEqual(controller.requestTermination(), .terminateLater)
        XCTAssertEqual(machine.requestStopCount, 1)
        XCTAssertTrue(replies.isEmpty)
        controller.machineDidStop(machine)
        XCTAssertEqual(replies, [true])
    }

    @MainActor
    func testGracefulShutdownTimeoutForcesStopBeforeReplying() async {
        let machine = MockTerminableMachine(canRequestStop: true, canStop: true)
        var replies: [Bool] = []
        var timeout: DispatchWorkItem?
        let replied = expectation(description: "application termination replied")
        let controller = OmarchyApplicationTerminationController(
            reply: { replies.append($0); replied.fulfill() }, scheduleTimeout: { timeout = $0 }
        )
        controller.register(machine)
        XCTAssertEqual(controller.requestTermination(), .terminateLater)

        timeout?.perform()
        XCTAssertEqual(machine.forceStopCount, 1)
        XCTAssertTrue(replies.isEmpty)
        machine.completeForcedStop()
        await fulfillment(of: [replied], timeout: 1)
        XCTAssertEqual(replies, [true])
    }
}

private final class MockTerminableMachine: OmarchyTerminableMachine {
    let canRequestStop: Bool
    let canStop: Bool
    private(set) var requestStopCount = 0
    private(set) var forceStopCount = 0
    private var completion: ((Error?) -> Void)?

    init(canRequestStop: Bool, canStop: Bool) {
        self.canRequestStop = canRequestStop
        self.canStop = canStop
    }

    func requestStop() throws { requestStopCount += 1 }

    func stop(completionHandler: @escaping (Error?) -> Void) {
        forceStopCount += 1
        completion = completionHandler
    }

    func completeForcedStop(error: Error? = nil) {
        let callback = completion
        completion = nil
        callback?(error)
    }
}
