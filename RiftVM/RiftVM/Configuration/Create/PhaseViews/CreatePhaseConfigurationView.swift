import SwiftUI
import Virtualization
#if arch(arm64)

/// Processor and memory for the Omarchy machine. The factory disk is fixed for
/// a release, so its row reports the size instead of offering a slider the
/// image would ignore.
struct CreateResourceControlsView: View {
    @Environment(OmarchyPreparationSettings.self) private var settings

    var body: some View {
        VStack(spacing: 0) {
            resourceRow(
                title: "Processors",
                detail: "\(ProcessInfo.processInfo.processorCount) logical cores available",
                value: "\(settings.cpuCount) CPU"
            ) {
                Slider(
                    value: cpuBinding,
                    in: Double(OmarchyPreparationSettings.minimumCPUCount)...Double(OmarchyPreparationSettings.maximumCPUCount),
                    step: 1
                )
                .accessibilityLabel("Processors")
                .accessibilityValue("\(settings.cpuCount)")
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
                value: "\(OmarchyPreparationSettings.storageBytes / .gibibyte) GB"
            ) {
                Slider(value: .constant(1), in: 0...1)
                    .accessibilityLabel("Storage")
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
            get: { Double(settings.cpuCount) },
            set: { settings.cpuCount = Int($0.rounded()) }
        )
    }

    private var memoryBinding: Binding<Double> {
        Binding(
            get: { Double(settings.memoryBytes / .gibibyte) },
            set: { settings.memoryBytes = UInt64($0.rounded()) * .gibibyte }
        )
    }

    private var minimumMemoryGiB: Double {
        Double(OmarchyPreparationSettings.minimumMemoryBytes / .gibibyte)
    }

    private var maximumMemoryGiB: Double {
        max(minimumMemoryGiB, Double(OmarchyPreparationSettings.maximumMemoryBytes / .gibibyte))
    }

    private var memoryGiB: UInt64 { settings.memoryBytes / .gibibyte }

    private var hostMemoryDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)
    }

    private var remainingMemoryDescription: String {
        let host = ProcessInfo.processInfo.physicalMemory
        let remaining = host > settings.memoryBytes ? host - settings.memoryBytes : 0
        return ByteCountFormatter.string(fromByteCount: Int64(remaining), countStyle: .memory)
    }
}

#endif
