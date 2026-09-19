import AppKit
import SwiftUI

/// Lists the Mac folders shared with Omarchy and lets the user add, remove, or
/// make them read-only. Changes are saved at once and reach a running Omarchy
/// without a restart.
struct OmarchySharedFoldersView: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: VMOmarchySharedFolderSettings
    /// The running session's layout; nil while Omarchy is stopped.
    let plan: VMOmarchySharePlan?
    /// The machine bundle, which must never be shared into its own guest.
    let machineRoot: URL
    let save: (VMOmarchySharedFolderSettings) -> Void
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Shared Folders").font(.title2.bold())
                Text(summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if settings.folders.isEmpty {
                ContentUnavailableView(
                    "No Shared Folders",
                    systemImage: "folder.badge.minus",
                    description: Text("Omarchy sees no Mac folders. Clipboard sharing keeps working.")
                )
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                List {
                    ForEach($settings.folders) { $folder in
                        row(for: $folder)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(minHeight: 160)
            }

            if !settings.guestSupportsMultipleFolders {
                Label {
                    Text("This Omarchy shares only the first writable folder, at /mnt/riftvm-shared. Install the RiftVM integration update inside Omarchy to share several folders.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Add Folder…", systemImage: "plus") { addFolder() }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var summary: String {
        settings.guestSupportsMultipleFolders
            ? "Each folder appears in Omarchy under /mnt/riftvm-shared. Changes apply immediately."
            : "Changes apply immediately."
    }

    @ViewBuilder
    private func row(for folder: Binding<VMOmarchySharedFolder>) -> some View {
        let value = folder.wrappedValue
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(value.path.lastPathComponent).font(.headline)
                Text(NSString(string: value.path.path(percentEncoded: false)).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let guestText = guestLocation(for: value) {
                    Text(guestText)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Toggle("Read Only", isOn: Binding(
                get: { folder.wrappedValue.readOnly },
                set: { folder.wrappedValue.readOnly = $0; commit() }
            ))
            .toggleStyle(.checkbox)
            Button {
                NSWorkspace.shared.open(value.path)
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            Button(role: .destructive) {
                settings.folders.removeAll { $0.id == value.id }
                commit()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop sharing this folder. Its files stay on your Mac.")
        }
        .padding(.vertical, 4)
    }

    private func guestLocation(for folder: VMOmarchySharedFolder) -> String? {
        if let plan {
            if let path = plan.guestPath(for: folder) { return "In Omarchy: \(path)" }
            return settings.guestSupportsMultipleFolders
                ? "Not shared: the folder is missing"
                : "Not shared with this Omarchy"
        }
        guard settings.guestSupportsMultipleFolders else { return nil }
        return "In Omarchy: \(VMOmarchySharePlan.guestMountPoint)/…"
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Share"
        panel.message = "Choose folders to share with Omarchy."
        guard panel.runModal() == .OK else { return }
        problem = nil
        for url in panel.urls {
            let candidate = url.standardizedFileURL
            if let reason = rejection(for: candidate) {
                problem = reason
                continue
            }
            settings.folders.append(VMOmarchySharedFolder(path: candidate))
        }
        commit()
    }

    private func rejection(for url: URL) -> String? {
        let path = url.resolvingSymlinksInPath().path
        let root = machineRoot.resolvingSymlinksInPath().path
        if path == root || path.hasPrefix(root + "/") || root.hasPrefix(path + "/") {
            return "\(url.lastPathComponent) contains or is inside the Omarchy machine, so it cannot be shared."
        }
        if settings.folders.contains(where: { $0.path.resolvingSymlinksInPath().path == path }) {
            return "\(url.lastPathComponent) is already shared."
        }
        return nil
    }

    private func commit() {
        save(settings)
    }
}
