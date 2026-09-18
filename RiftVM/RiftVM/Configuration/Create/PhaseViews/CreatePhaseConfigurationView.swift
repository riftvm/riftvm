//
//  CreatePhaseConfigurationView.swift
//  RiftVM
//
//  Created by everettjf on 2022/9/12.
//

import SwiftUI
import Virtualization


#if arch(arm64)
class CreatePhaseConfigurationViewHandler: VMCreateStepperGuidePhaseHandler {
    
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        .success
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        return .success
    }
}


struct CreatePhaseConfigurationView: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            CreateResourceControlsView()

            DisclosureGroup("Advanced hardware") {
                VMCreateConfigurationView(includePrimaryResources: false)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.bottom, 12)
    }
}

/// Processor, memory, and storage for the Omarchy workspace. The factory disk
/// is fixed for a release, so its row reports the size instead of offering a
/// slider that the image would ignore.
struct CreateResourceControlsView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData

    private let gibibyte = UInt64(1024 * 1024 * 1024)

    var body: some View {
        VStack(spacing: 0) {
            resourceRow(
                title: "Processors",
                detail: "\(ProcessInfo.processInfo.processorCount) logical cores available",
                value: "\(configData.cpuCount) CPU"
            ) {
                Slider(value: cpuBinding, in: Double(VMModelFieldCPU.minCount())...Double(VMModelFieldCPU.maxCount()), step: 1)
                    .accessibilityLabel("Processors")
                    .accessibilityValue("\(configData.cpuCount)")
            }

            Divider()

            resourceRow(
                title: "Memory",
                detail: "\(hostMemoryDescription) installed · \(remainingMemoryDescription) remains",
                value: "\(memoryGiB) GB"
            ) {
                Slider(value: memoryBinding, in: minimumMemoryGiB...maximumMemoryGiB, step: 1)
                    .accessibilityLabel("Memory")
                    .accessibilityValue("\(memoryGiB) gigabytes")
            }

            Divider()

            resourceRow(
                title: "Storage",
                detail: "Factory disk · fixed for this release",
                value: "\(storageGiB) GB"
            ) {
                Slider(value: storageBinding, in: minimumStorageGiB...maximumStorageGiB, step: 8)
                    .accessibilityLabel("Storage")
                    .accessibilityValue("\(storageGiB) gigabytes")
                    .disabled(true)
            }
        }
        .padding(.horizontal, 18)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.5), lineWidth: 1)
        }
    }

    private func resourceRow<Control: View>(
        title: String,
        detail: String,
        value: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180, alignment: .leading)

            control()

            Text(value)
                .monospacedDigit()
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.vertical, 16)
    }

    private var cpuBinding: Binding<Double> {
        Binding(
            get: { Double(configData.cpuCount) },
            set: { configData.cpuCount = Int($0.rounded()) }
        )
    }

    private var memoryBinding: Binding<Double> {
        Binding(
            get: { Double(configData.memorySize / gibibyte) },
            set: { configData.memorySize = UInt64($0.rounded()) * gibibyte }
        )
    }

    private var storageBinding: Binding<Double> {
        Binding(
            get: { Double(primaryStorage.size / gibibyte) },
            set: { updatePrimaryStorage(size: UInt64($0.rounded()) * gibibyte) }
        )
    }

    private var minimumMemoryGiB: Double {
        max(1, Double(VMModelFieldMemory.minSize() / gibibyte))
    }

    private var maximumMemoryGiB: Double {
        let hostGiB = Double(ProcessInfo.processInfo.physicalMemory / gibibyte)
        return max(minimumMemoryGiB, min(hostGiB - 2, Double(VMModelFieldMemory.maxSize() / gibibyte)))
    }

    private var minimumStorageGiB: Double {
        let rawMinimum = Double(VMModelFieldStorageDevice.minDiskSize()) / Double(gibibyte)
        return max(16, ceil(rawMinimum / 8) * 8)
    }

    private var maximumStorageGiB: Double {
        max(minimumStorageGiB, min(512, Double(VMModelFieldStorageDevice.maxDiskSize() / gibibyte)))
    }

    private var primaryStorage: VMModelFieldStorageDevice {
        configData.storageDevices.first(where: { $0.data.type == .Block })?.data ?? .default()
    }

    private var memoryGiB: UInt64 { configData.memorySize / gibibyte }
    private var storageGiB: UInt64 { primaryStorage.size / gibibyte }

    private var hostMemoryDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }

    private var remainingMemoryDescription: String {
        let remaining = ProcessInfo.processInfo.physicalMemory > configData.memorySize
            ? ProcessInfo.processInfo.physicalMemory - configData.memorySize
            : 0
        return ByteCountFormatter.string(fromByteCount: Int64(remaining), countStyle: .memory)
    }

    private func updatePrimaryStorage(size: UInt64) {
        guard let index = configData.storageDevices.firstIndex(where: { $0.data.type == .Block }) else { return }
        let existing = configData.storageDevices[index].data
        configData.storageDevices[index] = VMModelFieldStorageDeviceItemModel(
            data: VMModelFieldStorageDevice(
                type: existing.type,
                size: size,
                imagePath: existing.imagePath,
                format: existing.format
            )
        )
    }
}

struct CreatePhaseConfigurationView_Previews: PreviewProvider {
    static var previews: some View {
        CreatePhaseConfigurationView()
            .environment(VMConfigurationViewStateObject())
    }
}


#endif
