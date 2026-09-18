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
        .success
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        .success
    }
}

/// RiftVM prepares Omarchy workspaces, so this phase is a statement of what
/// will be downloaded rather than a choice. It stays on screen while the
/// workspace name and resources are chosen.
struct CreatePhaseSystemView: View {
    @Environment(VMConfigurationViewStateObject.self) private var configData

    var body: some View {
        SystemChoiceCard(
            title: "Omarchy",
            detail: "Preinstalled Arch Linux desktop, ready on first boot. RiftVM downloads and verifies the signed image after you click Create.",
            systemImage: "o.circle.fill",
            accent: .purple,
            badge: "INCLUDED"
        )
        .task {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(accent)
                .frame(width: 54, height: 54)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
            }

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .padding(18)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(accent, lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityIdentifier("system-choice-omarchy")
    }
}

#endif
