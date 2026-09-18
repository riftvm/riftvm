//
//  CreatePhaseSystemView.swift
//  RiftVM
//
//  Created by everettjf on 2026/8/18.
//

import SwiftUI

#if arch(arm64)

class CreatePhaseSystemViewHandler: VMCreateStepperGuidePhaseHandler {
    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        guard context.formData.hasChosenSystem else {
            return .failure("Choose a system before continuing.")
        }
        return .success
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        .success
    }
}

/// RiftVM prepares Omarchy workspaces, so this phase holds the one choice that
/// exists: the signed Omarchy factory image.
struct CreatePhaseSystemView: View {
    @Environment(VMCreateViewStateObject.self) private var formData
    @Environment(VMConfigurationViewStateObject.self) private var configData

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                systemSelection
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Prepare Omarchy")
                .font(.title2.weight(.semibold))
            Text("The image downloads and verifies after you click Create.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var systemSelection: some View {
        SystemChoiceCard(
            title: "Omarchy",
            detail: "Preinstalled Arch Linux desktop, ready on first boot",
            systemImage: "o.circle.fill",
            accent: .purple,
            badge: "Recommended",
            isSelected: formData.systemImageSelection == .preinstalled(.omarchy)
        ) {
            formData.systemImageSelection = .preinstalled(.omarchy)
            formData.hasChosenSystem = true
            configData.osType = .linux
        }
    }
}

private struct SystemChoiceCard: View {
    let title: String
    let detail: String
    let systemImage: String
    var accent: Color = .accentColor
    let badge: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? Color.white : accent)
                    .frame(width: 54, height: 54)
                    .background(isSelected ? accent : accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }

                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .padding(18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? accent.opacity(0.10) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? accent : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("system-choice-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

#endif
