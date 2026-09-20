import AppKit
import SwiftUI

/// Lists the Mac folders shared with Omarchy and lets the user add, remove, or
/// make them read-only. Changes are saved at once and reach Omarchy at its next
/// start: swapping a running share would pull the working directory out from
/// under every Guest program inside a shared folder.
struct OmarchySharedFoldersView: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: VMOmarchySharedFolderSettings
    /// The running session's layout; nil while Omarchy is stopped.
    let plan: VMOmarchySharePlan?
    /// The machine bundle, which must never be shared into its own guest.
    let machineRoot: URL
    let save: (VMOmarchySharedFolderSettings) -> Void
    /// Restarts a running Omarchy so it sees the saved list; nil while stopped.
    let restart: (() -> Void)?
    @State private var problem: String?

    /// The list Omarchy will see from its next start.
    private var nextPlan: VMOmarchySharePlan {
        VMOmarchySharePlan(settings: settings, transfer: machineRoot.appending(path: "Transfer"))
    }

    /// Saved changes the running session does not have yet.
    private var pendingRestart: Bool {
        guard let plan else { return false }
        return plan.settings.folders != settings.folders
    }

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

            if pendingRestart {
                HStack {
                    Label("Omarchy sees these changes after it restarts.", systemImage: "arrow.clockwise")
                        .font(.callout)
                    Spacer()
                    if let restart {
                        Button("Restart Omarchy") {
                            dismiss()
                            restart()
                        }
                    }
                }
                .padding(10)
                .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
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
        let when = plan == nil
            ? "Omarchy sees changes when it starts."
            : "Omarchy sees changes after it restarts, so running programs keep their folders."
        return "Each folder appears in Omarchy under /mnt/mac. \(when)"
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
        let next = nextPlan.guestPath(for: folder)
        if let plan, let now = plan.guestPath(for: folder),
           now == next, plan.settings.folders.contains(folder) {
            return "In Omarchy: \(now)"
        }
        if let next {
            return plan == nil ? "In Omarchy: \(next)" : "After restart: \(next)"
        }

        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder.path.path, isDirectory: &isDirectory) {
            return "Not shared: the folder is missing"
        }
        return "Not shared with this Omarchy"
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
