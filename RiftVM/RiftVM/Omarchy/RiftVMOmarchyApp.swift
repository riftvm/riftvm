import SwiftUI
import AppKit
import Virtualization

enum OmarchyWorkspaceConfiguration {
    static var acceptanceHarnessIncluded: Bool {
        #if RIFTVM_ACCEPTANCE_HARNESS
        true
        #else
        false
        #endif
    }

    static let acceptanceEnabledKey = "RIFTVM_OMARCHY_ACCEPTANCE"
    static let acceptanceRootKey = "RIFTVM_OMARCHY_ACCEPTANCE_WORKSPACE_ROOT"
    static let acceptanceUnlockPasswordKey = "RIFTVM_OMARCHY_ACCEPTANCE_UNLOCK_PASSWORD"
    static let acceptanceBootUnlockKey = "RIFTVM_OMARCHY_BOOT_UNLOCK_ACCEPTANCE"

    static func isAcceptanceWorkspace(
        _ workspace: VMOmarchyWorkspaceLayout,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard acceptanceHarnessIncluded, environment[acceptanceEnabledKey] == "1",
              let requested = try? layout(environment: environment) else { return false }
        return requested.applicationSupportRoot.resolvingSymlinksInPath().path ==
            workspace.applicationSupportRoot.resolvingSymlinksInPath().path
    }

    static func acceptanceOwnerProvisioningPassword(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        guard acceptanceHarnessIncluded, environment[acceptanceEnabledKey] == "1",
              (try? layout(environment: environment, fileManager: fileManager)) != nil,
              let password = environment[acceptanceUnlockPasswordKey],
              !password.isEmpty else { return nil }
        return password
    }

    static func layout(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> VMOmarchyWorkspaceLayout {
        guard environment[acceptanceEnabledKey] == "1" else {
            return try .userDomain(fileManager: fileManager)
        }
        guard let path = environment[acceptanceRootKey], path.hasPrefix("/") else {
            throw ConfigurationError.invalidAcceptanceRoot
        }
        let root = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard VMOmarchyTemporaryPathPolicy.contains(root, fileManager: fileManager) else {
            throw ConfigurationError.invalidAcceptanceRoot
        }
        return .init(applicationSupportRoot: root)
    }

    enum ConfigurationError: Error {
        case invalidAcceptanceRoot
    }

    /// The record of which Omarchy the window drives. An acceptance run keeps its
    /// own record inside its temporary machine, naming only that machine, so the
    /// harness can never open, lock or restart the user's Omarchy. An acceptance
    /// run with an invalid root stops instead of falling back to the user's record.
    static func workspaceStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ActiveWorkspaceStore {
        guard acceptanceHarnessIncluded, environment[acceptanceEnabledKey] == "1" else {
            return .standard
        }
        do {
            let root = try layout(environment: environment).applicationSupportRoot
            let store = ActiveWorkspaceStore(
                applicationSupportRoot: root.appending(path: "AcceptanceRecord", directoryHint: .isDirectory)
            )
            if try store.load()?.bundleURL.standardizedFileURL != root.standardizedFileURL {
                try store.adopt(bundleURL: root, name: "Omarchy Acceptance")
            }
            return store
        } catch {
            fatalError("Acceptance run without a valid temporary machine: \(error)")
        }
    }
}

struct OmarchyRootView: View {
    let profile: VMOmarchyProfile
    let workspaceManager: VMOmarchyWorkspaceManager
    /// The recorded Omarchy this window belongs to, and the actions the window
    /// offers for it (removal).
    let workspace: ActiveWorkspaceRecord
    let actions: WorkspaceWindowActions
    @State private var workspaceRevision = UUID()
    @State private var recoveryError: String?
    @State private var showsRecoveryConfirmation = false
    @State private var isMigrating = false

    var body: some View {
        switch workspaceManager.inspect() {
        case .notPrepared:
            // The window prepares Omarchy before it shows this view, so this is
            // the defensive branch for a bundle that vanished underneath it.
            ContentUnavailableView(
                "Omarchy is not ready",
                systemImage: "externaldrive.badge.questionmark",
                description: Text("Prepare Omarchy from the RiftVM window.")
            )
        case .ready:
            OmarchyVirtualMachineView(
                layout: workspaceManager.layout,
                profile: profile,
                workspace: workspace,
                actions: actions
            )
        case .migrationRequired(let fromVersion):
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Omarchy needs an update",
                    systemImage: "externaldrive.badge.timemachine",
                    description: Text("The on-disk format (\(fromVersion)) must be migrated before Omarchy can start.")
                )
                if let recoveryError {
                    Text(recoveryError).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                if isMigrating {
                    ProgressView("Creating protected backup and migrating…")
                } else {
                    Button("Create Backup and Migrate", systemImage: "arrow.triangle.2.circlepath") {
                        migrateWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(40)
        case .recovering(let reason):
            VStack(spacing: 18) {
                ContentUnavailableView(
                    "Omarchy needs recovery",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(reason)
                )
                if let recoveryError {
                    Text(recoveryError).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                HStack {
                    Button("Repair and Recheck", systemImage: "wrench.and.screwdriver") {
                        repairInterruptedRecovery()
                    }
                    Button("Reveal Data", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([workspaceManager.layout.workspace])
                    }
                    Button("Preserve and Reinstall…", systemImage: "arrow.counterclockwise") {
                        showsRecoveryConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(40)
            .confirmationDialog(
                "Preserve the broken Omarchy and reinstall it?",
                isPresented: $showsRecoveryConfirmation,
                titleVisibility: .visible
            ) {
                Button("Preserve and Reinstall") { preserveAndReinstall() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The existing data will be moved into the Recovery folder. It will not be deleted.")
            }
        }
    }

    private func preserveAndReinstall() {
        do {
            _ = try workspaceManager.quarantineBrokenWorkspace()
            recoveryError = nil
            workspaceRevision = UUID()
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    private func repairInterruptedRecovery() {
        do {
            try VMOmarchyRecoveryManager(workspaceManager: workspaceManager).recoverInterruptedOperations()
            recoveryError = nil
            workspaceRevision = UUID()
        } catch {
            recoveryError = error.localizedDescription
        }
    }

    private func migrateWorkspace() {
        guard !isMigrating else { return }
        isMigrating = true
        let manager = workspaceManager
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try manager.migrateWorkspace() }
            DispatchQueue.main.async {
                isMigrating = false
                switch result {
                case .success:
                    recoveryError = nil
                    workspaceRevision = UUID()
                case .failure(let error):
                    recoveryError = error.localizedDescription
                }
            }
        }
    }
}

enum FactoryTrustConfiguration {
    /// Every factory key this build accepts. The value is a set so a manifest
    /// signed by any configured key verifies, rather than only the newest one.
    /// Entries that are not a well-formed 32-byte key are dropped.
    static func publicKeys(bundle: Bundle = .main) -> [Data] {
        guard let encoded = bundle.object(forInfoDictionaryKey: "RiftVMOmarchyFactoryPublicKeysBase64") as? [String] else {
            return []
        }
        return encoded.compactMap { value in
            guard let data = Data(base64Encoded: value), data.count == 32 else { return nil }
            return data
        }
    }
}
