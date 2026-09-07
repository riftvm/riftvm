import AVFoundation
import CoreGraphics
import UserNotifications
import XCTest
@testable import RiftVM

final class OmarchyIntegrationTests: XCTestCase {
    func testStandardAudioDefaultsToSpeakersAndRequiresPermissionForInput() throws {
        XCTAssertEqual(VMModelFieldAudioDevice.default().type, .OutputStream)
        for status: AVAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            guard case .success(let speakers) = VMModelFieldAudioDevice.createConfigurations([.default()], microphoneAuthorization: status) else {
                return XCTFail("Speakers must not depend on microphone permission")
            }
            XCTAssertEqual(speakers.count, 1)
            for type: VMModelFieldAudioDevice.DeviceType in [.InputStream, .InputOutputStream] {
                guard case .failure(let message) = VMModelFieldAudioDevice.createConfigurations([.init(type: type)], microphoneAuthorization: status) else {
                    return XCTFail("Unapproved microphone input must not reach Virtualization")
                }
                XCTAssertTrue(message.contains("Manage Audio"))
            }
        }
        for type in VMModelFieldAudioDevice.DeviceType.allCases {
            guard case .success(let devices) = VMModelFieldAudioDevice.createConfigurations([.init(type: type)], microphoneAuthorization: .authorized) else {
                return XCTFail("Authorized microphone support must remain available")
            }
            XCTAssertEqual(devices.count, 1)
        }
    }

    @MainActor
    func testInstallerDisplayRemainsFixedAfterRefresh() throws {
        let creation = VMGraphicsBackendFactory.make(
            forLinux: true, devices: [], hasInstallationMedia: true
        )
        let installer = try XCTUnwrap(creation.backend as? VMAppleGraphicsBackend)
        XCTAssertFalse(installer.virtualMachineView.automaticallyReconfiguresDisplay)
        installer.refreshDisplayConfiguration()
        XCTAssertFalse(installer.virtualMachineView.automaticallyReconfiguresDisplay)

        let desktop = VMGraphicsBackendFactory.make(forLinux: false, devices: [])
        let mac = try XCTUnwrap(desktop.backend as? VMAppleGraphicsBackend)
        XCTAssertTrue(mac.virtualMachineView.automaticallyReconfiguresDisplay)
        mac.refreshDisplayConfiguration()
        XCTAssertTrue(mac.virtualMachineView.automaticallyReconfiguresDisplay)
    }

    func testOmarchySavedSessionIsCommittedAndConsumedTransactionally() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RiftVMSavedSession-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeSavedSessionFixture(root: root)
        let configuration = VMOmarchySavedSession.Configuration(cpuCount: 2, memoryBytes: 4 << 30, microphoneEnabled: false)
        let pending = try VMOmarchySavedSession.prepare(layout: layout)
        try Data("saved-memory".utf8).write(to: pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.workspace.appending(path: "SavedSession").path))
        try VMOmarchySavedSession.commit(layout: layout, configuration: configuration)
        let saved = try XCTUnwrap(VMOmarchySavedSession.stateToRestore(layout: layout, configuration: configuration))
        XCTAssertEqual(try Data(contentsOf: saved), Data("saved-memory".utf8))
        try VMOmarchySavedSession.discard(layout: layout)
        XCTAssertNil(try VMOmarchySavedSession.stateToRestore(layout: layout, configuration: configuration))
        XCTAssertEqual(try Data(contentsOf: layout.disk), Data("guest-disk".utf8))
    }

    func testInterruptedOmarchySessionRemainsAvailableForExplicitRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "RiftVMSavedSession-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = try makeSavedSessionFixture(root: root)
        let configuration = VMOmarchySavedSession.Configuration(cpuCount: 2, memoryBytes: 4 << 30, microphoneEnabled: false)
        let pending = try VMOmarchySavedSession.prepare(layout: layout)
        try Data("uncommitted-memory".utf8).write(to: pending)
        XCTAssertThrowsError(try VMOmarchySavedSession.stateToRestore(layout: layout, configuration: configuration))
        XCTAssertTrue(VMOmarchySavedSession.hasSession(layout: layout))
        XCTAssertEqual(try Data(contentsOf: pending), Data("uncommitted-memory".utf8))
    }

    func testOmarchySavedSessionRejectsChangedDiskIdentityPermissionsAndResources() throws {
        for mutation in ["disk", "identity", "permissions", "resources", "truncated-state"] {
            let root = FileManager.default.temporaryDirectory.appending(path: "RiftVMSavedSession-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let layout = try makeSavedSessionFixture(root: root)
            let original = VMOmarchySavedSession.Configuration(cpuCount: 2, memoryBytes: 4 << 30, microphoneEnabled: false)
            var current = original
            let pending = try VMOmarchySavedSession.prepare(layout: layout)
            try Data("saved-memory".utf8).write(to: pending)
            try VMOmarchySavedSession.commit(layout: layout, configuration: original)
            let saved = try XCTUnwrap(VMOmarchySavedSession.stateToRestore(layout: layout, configuration: original))
            switch mutation {
            case "disk": try Data("changed-guest-disk".utf8).write(to: layout.disk)
            case "identity": try Data("another-machine".utf8).write(to: layout.machineIdentifier)
            case "permissions": try Data("changed-folder-grants".utf8).write(to: root.appending(path: "FolderGrants.json"))
            case "resources": current = .init(cpuCount: 4, memoryBytes: 4 << 30, microphoneEnabled: false)
            default: try Data("cut".utf8).write(to: saved)
            }
            XCTAssertThrowsError(try VMOmarchySavedSession.stateToRestore(layout: layout, configuration: current), mutation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path), "An incompatible session must remain available for explicit recovery.")
        }
    }

    private func makeSavedSessionFixture(root: URL) throws -> VMOmarchyWorkspaceLayout {
        let layout = VMOmarchyWorkspaceLayout(applicationSupportRoot: root)
        try FileManager.default.createDirectory(at: layout.boot, withIntermediateDirectories: true)
        try Data("guest-disk".utf8).write(to: layout.disk)
        try Data("configuration".utf8).write(to: layout.configuration)
        try Data("machine".utf8).write(to: layout.machineIdentifier)
        try Data("efi".utf8).write(to: layout.efiVariableStore)
        return layout
    }

    func testAccessibilityRequestHasVisiblePendingState() {
        XCTAssertNotEqual(
            OmarchyKeyboardIntegrationState.requestingAccessibility,
            .accessibilityRequired
        )
        XCTAssertNotEqual(OmarchyKeyboardIntegrationState.requestingAccessibility, .enabled)
    }

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

    func testLockWatcherSeparatesChordRecognitionFromOmarchyLockAction() {
        let script = OmarchyInputDiagnosticsAcceptanceProbe.lockWatcherScript(
            guestDirectory: "/mnt/riftvm-shared/probe"
        )
        XCTAssertTrue(script.contains("command -v omarchy-shell"))
        XCTAssertTrue(script.contains("OMARCHY_SHELL_IPC_TIMEOUT=0.5s"))
        XCTAssertTrue(script.contains("[[ $state == true || $state == false ]]"))
        XCTAssertFalse(script.contains("hyprlock"))
    }

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
        ]), password)
    }

    func testDedicatedAppUsesOmarchyProductIdentity() throws {
        let profile = VMOmarchyProfile.production
        try profile.validate()
        XCTAssertEqual(profile.productID, "com.riftvm.app")
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
        let publicKeyURL = testFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/FactoryTrust/omarchy-factory-2026.pub")
        let publicKey = try Data(contentsOf: publicKeyURL)
        XCTAssertEqual(publicKey.count, 32)
        XCTAssertEqual(values["RiftVMOmarchyFactoryPublicKeyBase64"] as? String, publicKey.base64EncodedString())
        XCTAssertEqual(FactoryTrustConfiguration.publicKey(), publicKey)
        XCTAssertEqual(values["RiftVMSourceRevision"] as? String, "$(RIFTVM_SOURCE_REVISION)")
        XCTAssertEqual(values["RiftVMSourceTreeState"] as? String, "$(RIFTVM_SOURCE_TREE_STATE)")
        XCTAssertEqual(values["ITSAppUsesNonExemptEncryption"] as? Bool, false)
        XCTAssertEqual(
            values["NSMicrophoneUsageDescription"] as? String,
            "RiftVM uses the Mac microphone only when you enable microphone sharing for a workspace."
        )
    }

    func testStopRequestsGracefulStopAndWaitsForGuest() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.stopRequested), [.requestStop, .scheduleStopTimeout])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertFalse(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelStopTimeout])
        XCTAssertEqual(lifecycle.phase, .stopped)
    }

    func testRestartStartsNewSessionOnlyAfterGuestStops() {
        var lifecycle = runningLifecycle()

        XCTAssertEqual(lifecycle.handle(.restartRequested), [.requestStop, .scheduleStopTimeout])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertTrue(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelStopTimeout, .startNewSession])
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
        XCTAssertEqual(stopping.handle(.stopRequested), [.requestStop, .scheduleStopTimeout])
        XCTAssertEqual(stopping.phase, .stopping)

        var restarting = runningLifecycle()
        _ = restarting.handle(.pauseRequested)
        _ = restarting.handle(.machinePaused)
        XCTAssertEqual(restarting.handle(.restartRequested), [.requestStop, .scheduleStopTimeout])
        XCTAssertTrue(restarting.restartAfterStop)
    }

    func testFailureCancelsPendingRestartAndCanBeRetried() {
        var lifecycle = runningLifecycle()
        _ = lifecycle.handle(.restartRequested)

        XCTAssertEqual(lifecycle.handle(.machineFailed("disk unavailable")), [.cancelStopTimeout])
        XCTAssertEqual(lifecycle.phase, .failed("disk unavailable"))
        XCTAssertFalse(lifecycle.restartAfterStop)
        XCTAssertEqual(lifecycle.handle(.startRequested), [.startNewSession])
        XCTAssertEqual(lifecycle.phase, .starting)
    }

    func testGracefulStopTimeoutRequiresExplicitForceAuthorization() {
        var lifecycle = runningLifecycle()
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [])
        _ = lifecycle.handle(.stopRequested)
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [.askStopTimeout])
        XCTAssertEqual(lifecycle.handle(.keepWaiting), [.scheduleStopTimeout])
        XCTAssertEqual(lifecycle.handle(.forceStopConfirmed), [.forceStop])
        XCTAssertEqual(lifecycle.phase, .stopping)
        XCTAssertEqual(lifecycle.handle(.machineStopped), [.cancelStopTimeout])
        XCTAssertEqual(lifecycle.handle(.stopTimedOut), [])
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

    @MainActor
    func testDynamicDisplayProbeDecodesActiveHyprlandMonitor() throws {
        let data = Data(#"[{"disabled":true,"width":1,"height":1},{"disabled":false,"width":1440,"height":900}]"#.utf8)
        XCTAssertEqual(
            try OmarchyDynamicDisplayAcceptanceProbe.decodeDisplay(data),
            OmarchyDisplaySize(width: 1440, height: 900)
        )
        XCTAssertThrowsError(try OmarchyDynamicDisplayAcceptanceProbe.decodeDisplay(Data("[]".utf8)))
    }

    private func runningLifecycle() -> OmarchyMachineLifecycle {
        var lifecycle = OmarchyMachineLifecycle()
        XCTAssertEqual(lifecycle.handle(.machineStarted), [])
        XCTAssertEqual(lifecycle.phase, .running)
        return lifecycle
    }

    @MainActor
    func testMirroredClipboardNeverCrossesIntoAnotherWorkspace() {
        let ownership = HostClipboardCoordinator()
        let first = UUID(), second = UUID()
        XCTAssertTrue(ownership.canSend(changeCount: 10, to: first))
        ownership.didReceive(changeCount: 11, from: first)
        XCTAssertTrue(ownership.canSend(changeCount: 11, to: first))
        XCTAssertFalse(ownership.canSend(changeCount: 11, to: second))
        XCTAssertTrue(ownership.canSend(changeCount: 12, to: second))
    }

    @MainActor
    func testQuitWaitsForAllWorkspacesAndDoesNotIssueDuplicateRequests() {
        let first = QuitMachine(saveSupported: true), second = QuitMachine(saveSupported: false)
        var replies: [Bool] = []
        let controller = WorkspaceQuitController(participants: { [first.participant, second.participant] },
            confirmShutdown: { true }, chooseTimeout: { .wait }, reply: { replies.append($0) }, schedulePoll: { _ in })
        XCTAssertEqual(controller.requestTermination(), .terminateLater)
        XCTAssertEqual(controller.requestTermination(), .terminateLater)
        XCTAssertEqual(first.saves, 1)
        XCTAssertEqual(second.shutdowns, 1)
        first.stopped = true
        controller.poll()
        XCTAssertTrue(replies.isEmpty)
        second.stopped = true
        controller.poll()
        XCTAssertEqual(replies, [true])
    }

    @MainActor
    func testTimeoutWaitAndCancelNeverForceStop() {
        let machine = QuitMachine(saveSupported: false)
        var choice = WorkspaceQuitController.TimeoutChoice.wait
        var replies: [Bool] = []
        let controller = WorkspaceQuitController(participants: { [machine.participant] },
            confirmShutdown: { true }, chooseTimeout: { choice }, reply: { replies.append($0) }, schedulePoll: { _ in })
        XCTAssertEqual(controller.requestTermination(), .terminateLater)
        controller.handleTimeout()
        XCTAssertTrue(controller.isPending)
        XCTAssertEqual(machine.forcedStops, 0)
        choice = .cancel
        controller.handleTimeout()
        XCTAssertEqual(replies, [false])
        XCTAssertFalse(controller.isPending)
        XCTAssertEqual(machine.forcedStops, 0)
    }

    @MainActor
    func testForceStopNeedsExplicitChoiceAndActualCompletion() {
        let machine = QuitMachine(saveSupported: false)
        var replies: [Bool] = []
        let controller = WorkspaceQuitController(participants: { [machine.participant] },
            confirmShutdown: { true }, chooseTimeout: { .forceStop }, reply: { replies.append($0) }, schedulePoll: { _ in })
        XCTAssertEqual(controller.requestTermination(), .terminateLater)
        controller.handleTimeout()
        XCTAssertEqual(machine.forcedStops, 1)
        XCTAssertTrue(replies.isEmpty)
        machine.stopped = true
        controller.poll()
        XCTAssertEqual(replies, [true])
    }

    @MainActor
    func testCancelInitialQuitDoesNotChangeAnyGuest() {
        let machine = QuitMachine(saveSupported: false)
        let controller = WorkspaceQuitController(participants: { [machine.participant] },
            confirmShutdown: { false }, chooseTimeout: { .forceStop }, schedulePoll: { _ in })
        XCTAssertEqual(controller.requestTermination(), .terminateCancel)
        XCTAssertEqual(machine.shutdowns, 0)
        XCTAssertEqual(machine.forcedStops, 0)
    }
}

@MainActor private final class QuitMachine {
    let id = UUID().uuidString
    let saveSupported: Bool
    var stopped = false
    var saves = 0
    var shutdowns = 0
    var forcedStops = 0
    init(saveSupported: Bool) { self.saveSupported = saveSupported }
    var participant: WorkspaceQuitController.Participant {
        .init(id: id, isStopped: { self.stopped }, canSave: { self.saveSupported },
              save: { self.saves += 1 }, shutDown: { self.shutdowns += 1 }, forceStop: { self.forcedStops += 1 })
    }
}
