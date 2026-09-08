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
        if case .localFile(let url) = context.formData.systemImageSelection,
           !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            return .failure("The selected system image no longer exists: \(url.path(percentEncoded: false))")
        }
        return .success
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        .success
    }
}

struct CreatePhaseSystemView: View {
    @Environment(VMCreateViewStateObject.self) private var formData
    @Environment(VMConfigurationViewStateObject.self) private var configData

    @State private var customImageURL = ""
    @State private var showingMacOSVersions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if showingMacOSVersions {
                    macOSVersionSelection
                } else {
                    systemSelection
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 12)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Choose a system")
                .font(.title2.weight(.semibold))
            Text(showingMacOSVersions
                 ? "Choose a compatible restore image. Downloading starts only after you click Create."
                 : "What would you like to run?")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var systemSelection: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 14) {
            SystemChoiceCard(
                title: "Omarchy",
                detail: "Preinstalled Arch Linux desktop, ready on first boot",
                systemImage: "o.circle.fill",
                accent: .purple,
                badge: "Recommended",
                isSelected: formData.systemImageSelection == .preinstalled(.omarchy)
            ) {
                switchOSType(.linux)
                selectImage(.preinstalled(.omarchy))
            }

            SystemChoiceCard(
                title: "macOS",
                detail: "Choose a compatible macOS restore image",
                systemImage: "apple.logo",
                accent: .blue,
                badge: "Choose version",
                isSelected: configData.osType == .macOS && formData.hasChosenSystem
            ) {
                switchOSType(.macOS)
                showingMacOSVersions = true
            }
        }
    }

    private var macOSVersionSelection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("All systems", systemImage: "chevron.left") {
                showingMacOSVersions = false
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            MacOSImageSelectionView(
                selection: formData.systemImageSelection,
                customURL: $customImageURL,
                onSelect: selectImage,
                onChooseLocal: selectFromFileSystem
            )
        }
    }

    private func selectImage(_ selection: VMCreateViewStateObject.SystemImageSelection) {
        formData.systemImageSelection = selection
        formData.hasChosenSystem = true
        if case .localFile(let url) = selection {
            formData.imagePath = url.path(percentEncoded: false)
        } else {
            formData.imagePath = ""
        }
        if case .preinstalled(let item) = selection {
            let resources = VMPreinstalledImageResourceRecommendation.recommended()
            configData.cpuCount = resources.cpuCount
            configData.memorySize = resources.memorySize
            configData.linuxFeatures = .recommended
            configData.name = item.name
            formData.hasGeneratedNameSuggestion = true
            configData.remark = item.detail
        }
    }

    private func switchOSType(_ osType: VMOSType) {
        guard configData.osType != osType else { return }
        let existingName = configData.name
        configData.osType = osType
        configData.resetDefaultConfig()
        if formData.hasGeneratedNameSuggestion {
            configData.name = existingName
        }
        formData.imagePath = ""
        formData.hasChosenSystem = false
        formData.systemImageSelection = osType == .macOS
            ? .latestMacOS
            : .preinstalled(.omarchy)
    }

    private func selectFromFileSystem() {
        let fileType = configData.osType == .macOS ? "IPSW" : "ISO"
        MacKitUtil.selectFile(title: "Choose a \(fileType) system image") { path in
            guard let path else { return }
            selectImage(.localFile(path))
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

private struct MacOSImageSelectionView: View {
    let selection: VMCreateViewStateObject.SystemImageSelection
    @Binding var customURL: String
    let onSelect: (VMCreateViewStateObject.SystemImageSelection) -> Void
    let onChooseLocal: () -> Void

    @State private var catalog = VMMacOSImageCatalogService()
    @State private var showAllReleases = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SelectionSectionHeading(
                    title: "macOS restore image",
                    subtitle: "Choose the newest compatible release or a specific version from Apple."
                )
                Spacer()
                Button {
                    Task { await catalog.refresh(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(catalog.isRefreshing)
                .accessibilityIdentifier("refresh-macos-catalog")
            }

            ImageChoiceButton(
                title: "Latest compatible macOS",
                detail: "Automatically resolved through Apple",
                systemImage: "sparkles",
                accent: .blue,
                badge: VMImageStore.exists(fileName: "macOS-Latest.ipsw") ? "Downloaded" : "Recommended",
                isSelected: selection == .latestMacOS,
                identifier: "macos-latest-image"
            ) {
                onSelect(.latestMacOS)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    if catalog.isRefreshing {
                        ProgressView().controlSize(.small)
                        Text("Updating available versions…")
                    } else if let errorMessage = catalog.errorMessage {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(errorMessage)
                    } else {
                        Image(systemName: "network").foregroundStyle(.green)
                        Text(catalogStatusText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("The Apple-hosted release list updates automatically via IPSW.me. Downloads come directly from Apple; RiftVM asks Apple’s installation service for the final host compatibility check.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if !catalog.items.isEmpty {
                    Text("Recommended releases")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(catalog.featuredItems) { item in
                        ImageChoiceButton(
                            title: item.name,
                            detail: item.detail,
                            systemImage: "shippingbox",
                            accent: .indigo,
                            badge: cachedBadge(for: item),
                            isSelected: selectedCatalogID == item.id,
                            identifier: "macos-image-\(item.id)"
                        ) {
                            onSelect(.catalog(item))
                        }
                    }

                    DisclosureGroup("All available releases (\(catalog.items.count))", isExpanded: $showAllReleases) {
                        LazyVStack(spacing: 8) {
                            ForEach(catalog.items) { item in
                                ImageChoiceButton(
                                    title: item.name,
                                    detail: item.detail,
                                    systemImage: "shippingbox",
                                    accent: .indigo,
                                    badge: cachedBadge(for: item),
                                    isSelected: selectedCatalogID == item.id,
                                    identifier: "macos-image-\(item.id)"
                                ) {
                                    onSelect(.catalog(item))
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("Direct Apple IPSW URL", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("macos-custom-url-field")
                Button("Use URL") {
                    guard let url = validatedCustomURL else { return }
                    onSelect(.remoteURL(url))
                }
                .disabled(validatedCustomURL == nil)
            }

            LocalImageButton(fileType: "IPSW", selectedPath: localPath, action: onChooseLocal)
        }
        .task { await catalog.refresh() }
    }

    private var localPath: String {
        if case .localFile(let url) = selection { return url.path(percentEncoded: false) }
        return ""
    }

    private var selectedCatalogID: String? {
        if case .catalog(let item) = selection { return item.id }
        return nil
    }

    private var validatedCustomURL: URL? {
        guard let url = URL(string: customURL),
              url.scheme?.lowercased() == "https",
              url.pathExtension.lowercased() == "ipsw" else { return nil }
        return url
    }

    private var catalogStatusText: String {
        guard let lastUpdated = catalog.lastUpdated else {
            return "Online catalog not updated yet"
        }
        if abs(lastUpdated.timeIntervalSinceNow) < 60 {
            return "Online catalog updated just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Online catalog updated \(formatter.localizedString(for: lastUpdated, relativeTo: Date()))"
    }

    private func cachedBadge(for item: VMSystemImageCatalogItem) -> String? {
        let ext = item.url.pathExtension.isEmpty ? "ipsw" : item.url.pathExtension
        return VMImageStore.exists(fileName: "\(item.id).\(ext)") ? "Downloaded" : nil
    }
}

private struct ImageChoiceButton: View {
    let title: String
    let detail: String
    let systemImage: String
    let accent: Color
    var badge: String? = nil
    var isSelected = false
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 32)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(accent.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? accent.opacity(0.10) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? accent : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
        }
        .accessibilityLabel("\(title), \(detail)")
        .accessibilityIdentifier(identifier)
    }
}

private struct LocalImageButton: View {
    let fileType: String
    let selectedPath: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "externaldrive")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a local \(fileType) file")
                        .font(.headline)
                    Text(selectedPath.isEmpty ? "Browse this Mac or an external drive" : "Replace the currently selected image")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                .foregroundStyle(.separator)
        }
        .accessibilityIdentifier("choose-local-system-image")
    }
}

private struct SelectionSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CreatePhaseSystemView_Previews: PreviewProvider {
    static let formData = VMCreateViewStateObject()
    static let configData = VMConfigurationViewStateObject()

    static var previews: some View {
        CreatePhaseSystemView()
            .frame(width: 720, height: 620)
            .environment(formData)
            .environment(configData)
    }
}

#endif
