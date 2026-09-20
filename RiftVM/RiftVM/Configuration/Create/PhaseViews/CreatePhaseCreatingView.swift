//
//  CreatePhaseCreatingView.swift
//  RiftVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI
import Virtualization

#if arch(arm64)

/// Prepares the one thing RiftVM creates: an Omarchy workspace backed by the
/// signed factory image. The download is verified against the trusted signing
/// keys, and the verified disk is then handed to the workspace manager.
class CreatePhaseCreatingViewHandler: VMCreateStepperGuidePhaseHandler {
    private var factoryCancellationRequested = false
    private var factoryTransport: VMOmarchyURLSessionTransport?

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        return .success
    }

    func cancel(context: VMCreateStepperGuidePhaseContext) {
        guard context.formData.canCancelCreation else { return }
        let cancellationKind = context.formData.creationCancellationKind
        context.formData.canCancelCreation = false
        context.formData.creationCancellationKind = nil
        // The only cancellable stage is the verified factory download.
        guard cancellationKind == .download else { return }
        if factoryTransport != nil { factoryCancellationRequested = true }
        factoryTransport?.cancel()
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        context.formData.logs = []
        context.formData.downloadBytesReceived = nil
        context.formData.downloadBytesExpected = nil
        context.formData.installingProgress = 0
        context.formData.creationStage = "Preparing"
        context.formData.isCreating = true
        context.formData.canCancelCreation = false
        context.formData.creationCancellationKind = nil

        let result = await createOmarchyWorkspace(context: context)
        context.formData.isCreating = false
        if case .success = result {
            context.formData.creationStage = "Ready"
            context.formData.changeProgress(1)
            context.formData.disablePreviousButton = true
            registerCreatedWorkspace(context: context)
        }
        return result
    }

    private func createOmarchyWorkspace(
        context: VMCreateStepperGuidePhaseContext
    ) async -> VMOSResultVoid {
        let profile = VMOmarchyProfile.production
        let layout = VMOmarchyWorkspaceLayout.appWorkspace(
            bundleURL: URL(filePath: context.formData.rootPath, directoryHint: .isDirectory)
        )
        let manager = VMOmarchyWorkspaceManager(layout: layout)

        do {
            let forecast = try VMOmarchyStorageForecast.inspect(
                volumeContaining: layout.applicationSupportRoot.deletingLastPathComponent(),
                downloadBytes: profile.factoryImage.maximumDownloadBytes,
                workspaceBytes: profile.factoryImage.maximumDownloadBytes
            )
            guard forecast.hasEnoughSpace else {
                throw OmarchyCreationError.insufficientSpace(
                    required: forecast.requiredBytes,
                    available: forecast.availableBytes
                )
            }
            let publicKeys = FactoryTrustConfiguration.publicKeys()
            guard !publicKeys.isEmpty else {
                throw OmarchyCreationError.releaseChannelNotConfigured
            }
            let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "RiftVM", directoryHint: .isDirectory)
            let transport = VMOmarchyURLSessionTransport()
            factoryCancellationRequested = false
            factoryTransport = transport
            context.formData.canCancelCreation = true
            context.formData.creationCancellationKind = .download
            defer {
                transport.cancel()
                factoryTransport = nil
                context.formData.canCancelCreation = false
                context.formData.creationCancellationKind = nil
            }
            let installer = VMOmarchyFactoryInstaller(
                profile: profile,
                cacheDirectory: supportRoot.appending(path: "FactoryCache", directoryHint: .isDirectory),
                publicKeys: publicKeys,
                transport: transport
            )
            context.formData.creationStage = "Downloading and verifying Omarchy"
            context.formData.addLog("Fetching the signed Omarchy Factory manifest")
            let factory = try await installer.install(stage: { stage in
                Task { @MainActor in
                    context.formData.creationStage = stage
                    if !stage.hasPrefix("Downloading") {
                        context.formData.downloadBytesReceived = nil
                        context.formData.downloadBytesExpected = nil
                    }
                }
            }) { received, expected in
                let fraction = Double(received) / Double(max(expected, 1))
                Task { @MainActor in
                    context.formData.downloadBytesReceived = received
                    context.formData.downloadBytesExpected = expected
                    context.formData.changeProgress(min(max(fraction, 0), 1) * 0.82)
                }
            }
            if factoryCancellationRequested { throw CancellationError() }
            context.formData.canCancelCreation = false
            context.formData.creationCancellationKind = nil
            context.formData.downloadBytesReceived = nil
            context.formData.downloadBytesExpected = nil
            context.formData.creationStage = "Creating Omarchy"
            context.formData.addLog("Factory image verified; creating the disk and integration identity")
            let metadata = try JSONEncoder().encode(VMOmarchyWorkspaceMetadata(
                productID: profile.productID,
                createdAt: Date(),
                factoryImageVersion: factory.manifest.payload.imageVersion,
                omarchyRevision: factory.manifest.payload.omarchyRevision,
                guestAgentVersion: factory.manifest.payload.guestAgentVersion,
                guestCapabilities: factory.manifest.payload.guestCapabilities.sorted(),
                cpuCount: context.configData.cpuCount,
                memoryBytes: context.configData.memoryBytes
            ))
            let sharedFolder = context.configData.sharedFolderPath.isEmpty
                ? VMOmarchySharedFolderStore.defaultFolder(forBundle: layout.applicationSupportRoot)
                : URL(filePath: context.configData.sharedFolderPath, directoryHint: .isDirectory)
            try manager.prepare(
                factoryDisk: factory.diskURL,
                configuration: metadata,
                machineIdentifier: VZGenericMachineIdentifier().dataRepresentation,
                sharedFolders: VMOmarchySharedFolderSettings(folders: [VMOmarchySharedFolder(path: sharedFolder)])
            )
            context.formData.changeProgress(1)
            context.formData.addLog("Omarchy is ready")
            return .success
        } catch {
            if factoryCancellationRequested {
                context.formData.creationStage = "Creation cancelled"
                return .failure("Creation was cancelled. You can retry when you’re ready.")
            }
            context.formData.creationStage = "Couldn’t prepare Omarchy"
            context.formData.addLog("❌ \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    private enum OmarchyCreationError: LocalizedError {
        case releaseChannelNotConfigured
        case insufficientSpace(required: UInt64, available: UInt64)

        var errorDescription: String? {
            switch self {
            case .releaseChannelNotConfigured:
                "This build has no trusted Omarchy Factory signing key."
            case .insufficientSpace(let required, let available):
                "Omarchy needs \(Self.bytes(required)) free; this volume currently has \(Self.bytes(available))."
            }
        }

        private static func bytes(_ value: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
        }
    }

    private func registerCreatedWorkspace(context: VMCreateStepperGuidePhaseContext) {
        let rootPath = URL(filePath: context.formData.rootPath)
        sharedAppConfigManager.addVMPathWithRefresh(url: rootPath)
        do {
            _ = try ActiveWorkspaceStore.standard.adopt(
                bundleURL: rootPath,
                name: OmarchyPreparationSettings.machineName
            )
        } catch {
            let message = "The Omarchy record could not be saved: \(error.localizedDescription)"
            context.formData.addLog("⚠️ \(message)")
            RiftVMLog.error(message, logger: RiftVMLog.lifecycle)
        }
    }
}

struct CreatePhaseCreatingView: View {
    @Environment(VMCreateViewStateObject.self) var formData

    @State private var showDetails = false

    var body: some View {
        VStack {
            Image(systemName: formData.creationStage == "Ready" ? "checkmark.circle.fill" : "shippingbox.and.arrow.backward")
                .font(.system(size: 42))
                .foregroundStyle(formData.creationStage == "Ready" ? Color.green : Color.accentColor)

            Text(formData.creationStage)
                .font(.title2.weight(.semibold))

            Text("RiftVM downloads and verifies the signed Omarchy image, then creates the machine. You can leave this window open and wait once.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            // current activity headline, so the user does not have to read logs
            HStack(spacing: 12) {
                if formData.isCreating {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(formData.statusText)
                    .lineLimit(2)
                Spacer()
            }

            HStack(spacing: 12) {
                Text("\(String(format: "%.0f", 100 * formData.installingProgress))%")
                    .font(.caption)
                ProgressView(value: 100 * formData.installingProgress, total: 100)
            }

            DisclosureGroup("Installation details", isExpanded: $showDetails) {
                List {
                    ForEach(formData.logs) { item in
                        HStack {
                            Text(item.time)
                                .foregroundStyle(.secondary)
                            Text(item.log)
                                .lineLimit(0)
                                .multilineTextAlignment(.leading)
                        }
                        .font(.caption)
                    }
                }
                .frame(minHeight: 180)
            }

            Spacer()
        }
        .padding(24)
        .onChange(of: formData.statusText) {
            // surface the full log as soon as something goes wrong
            if formData.statusText.hasPrefix("❌") {
                showDetails = true
            }
        }
    }
}

struct CreatePhaseCreatingView_Previews: PreviewProvider {
    static var previews: some View {
        let formData = VMCreateViewStateObject()
        CreatePhaseCreatingView()
            .environment(formData)
    }
}


#endif
