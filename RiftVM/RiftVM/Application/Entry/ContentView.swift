import AppKit
import SwiftUI
import Virtualization

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var manager = sharedAppConfigManager
    @State private var coordinator = WorkspaceCoordinator.shared
    @State private var search = ""
    @State private var didRoute = false
    @State private var snapshotWorkspace: WorkspaceRecord?
    @State private var settingsWorkspace: WorkspaceRecord?
    @State private var portabilityOperation: String?

    private var workspaces: [WorkspaceRecord] {
        manager.workspaces.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Your next workspace.")
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                        Text("Another world, right on your Mac.")
                            .font(.title3).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 16) {
                        createCard("Omarchy", detail: "A focused Linux desktop for making things.", symbol: "terminal", tint: .orange, profile: .omarchy)
                        createCard("macOS", detail: "A separate Mac for a fresh perspective.", symbol: "macwindow", tint: .blue, profile: .macOS)
                    }
                    if let error = manager.errorMessage {
                        ContentUnavailableView("Workspace library needs attention", systemImage: "exclamationmark.triangle", description: Text(error))
                        Button("Retry") { manager.loadConfig() }
                    } else if !manager.workspaces.isEmpty {
                        HStack {
                            Text("Workspaces").font(.title2.weight(.semibold))
                            Spacer()
                            Text("\(manager.workspaces.count)").foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 16)], spacing: 16) {
                            ForEach(workspaces) { workspace in
                                workspaceCard(workspace)
                            }
                        }
                    }
                    HStack {
                        Button("Custom Linux ISO", systemImage: "opticaldisc") {
                            openWindow(id: "create-workspace", value: WorkspaceProfile.linux)
                        }
                        Button("Open Existing Workspace…", systemImage: "folder") { manager.addVMPathWithSelect() }
                        Button("Import as New Workspace…", systemImage: "square.and.arrow.down") { importMachine() }
                            .disabled(portabilityOperation != nil)
                    }
                    .buttonStyle(.borderless)
                    if let portabilityOperation {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(portabilityOperation).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("Apple Silicon · macOS 27").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(36)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("RiftVM")
            .searchable(text: $search, prompt: "Find a workspace")
            .toolbar {
                ToolbarItem {
                    Button("New Workspace", systemImage: "plus") { openWindow(id: "create-machine-guide") }
                }
            }
        }
        .sheet(item: $snapshotWorkspace) { workspace in
            MachineSnapshotsView(machineName: workspace.name, rootPath: workspace.location)
        }
        .sheet(item: $settingsWorkspace) { workspace in
            if case .success(let model) = VMModel.loadConfigFromFile(rootPath: workspace.location) {
                VMEditConfigurationView(model: model)
            }
        }
        .task {
            guard !didRoute else { return }
            didRoute = true
            // Test probes require the library to remain visible.
            guard ProcessInfo.processInfo.environment["RIFTVM_GUI_READY_FILE"] == nil,
                  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            if case .open(let id) = manager.launchRoute,
               let workspace = manager.workspaces.first(where: { $0.id == id }) { coordinator.open(workspace) }
        }
    }

    private func createCard(_ title: String, detail: String, symbol: String, tint: Color, profile: WorkspaceProfile) -> some View {
        Button {
            openWindow(id: "create-workspace", value: profile)
        } label: {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.title2.weight(.semibold)).foregroundStyle(.primary)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Label("Create workspace", systemImage: "arrow.up.right").font(.callout.weight(.medium)).foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            .padding(24)
            .background(tint.opacity(0.06), in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(tint.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create \(title) workspace")
    }

    private func exportMachine(_ model: VMModel) {
        guard portabilityOperation == nil else { return }
        guard let maintenanceLease = VMRunningRegistry.shared.acquire(rootPath: model.rootPath, phase: .maintaining) else {
            MacKitUtil.alertWarn(title: "Machine is busy", message: "Shut down the virtual machine and wait for other maintenance operations before exporting it.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Virtual Machine"
        panel.nameFieldStringValue = "\(model.config.name).riftvmexport"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, var destination = panel.url else {
            VMRunningRegistry.shared.release(maintenanceLease)
            return
        }
        if destination.pathExtension != VMPortabilityManager.exportExtension {
            destination.appendPathExtension(VMPortabilityManager.exportExtension)
        }
        let source = model.rootPath
        portabilityOperation = "Exporting workspace… Keep RiftVM open until this finishes."
        Task.detached {
            let result = VMPortabilityManager.exportMachine(sourceURL: source, destinationURL: destination)
            await MainActor.run {
                VMRunningRegistry.shared.release(maintenanceLease)
                portabilityOperation = nil
                switch result {
                case .success: MacKitUtil.alertInfo(title: "Export complete", message: destination.path)
                case .failure(let error): MacKitUtil.alertWarn(title: "Export failed", message: error)
                }
            }
        }
    }

    private func importMachine() {
        guard portabilityOperation == nil else { return }
        let openPanel = NSOpenPanel()
        openPanel.title = "Select a RiftVM Export"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        guard openPanel.runModal() == .OK, let source = openPanel.url else { return }
        guard source.pathExtension == VMPortabilityManager.exportExtension else {
            MacKitUtil.alertWarn(title: "Import failed", message: "Select a .riftvmexport package.")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.title = "Import as New Workspace"
        let suggested = source.deletingPathExtension().lastPathComponent
        savePanel.nameFieldStringValue = "\(suggested).riftvm"
        savePanel.canCreateDirectories = true
        guard savePanel.runModal() == .OK, var destination = savePanel.url else { return }
        if destination.pathExtension != "riftvm" { destination.appendPathExtension("riftvm") }
        let importedName = destination.deletingPathExtension().lastPathComponent
        let exportedConfig = source
            .appendingPathComponent(VMPortabilityManager.payloadDirectoryName, isDirectory: true)
            .appendingPathComponent("config.json")
        let exportedType = (try? JSONSerialization.jsonObject(with: Data(contentsOf: exportedConfig)))
            .flatMap { $0 as? [String: Any] }?["type"] as? String
        let identifier = exportedType == "macOS"
            ? VZMacMachineIdentifier().dataRepresentation
            : VZGenericMachineIdentifier().dataRepresentation
        portabilityOperation = "Importing workspace… Keep RiftVM open until this finishes."
        Task.detached {
            let result = VMPortabilityManager.importMachine(
                exportURL: source,
                destinationURL: destination,
                identityMode: .copy(machineIdentifierData: identifier, name: importedName)
            )
            await MainActor.run {
                portabilityOperation = nil
                switch result {
                case .success:
                    sharedAppConfigManager.addVMPathWithRefresh(url: destination)
                    MacKitUtil.alertInfo(title: "Import complete", message: destination.lastPathComponent)
                case .failure(let error): MacKitUtil.alertWarn(title: "Import failed", message: error)
                }
            }
        }
    }

    private func workspaceCard(_ workspace: WorkspaceRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: workspace.profile.symbol).font(.title2).foregroundStyle(.secondary)
                Spacer()
                if manager.defaultID == workspace.id { Label("Default", systemImage: "star.fill").font(.caption).foregroundStyle(.orange) }
                Menu {
                    Button(manager.defaultID == workspace.id ? "Clear Default" : "Make Default") {
                        manager.setDefault(manager.defaultID == workspace.id ? nil : workspace.id)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([workspace.location]) }
                    if workspace.profile != .omarchy {
                        Button("Settings…") { settingsWorkspace = workspace }
                        Button("Snapshots…") { snapshotWorkspace = workspace }
                        Button("Export Workspace…") {
                            switch VMModel.loadConfigFromFile(rootPath: workspace.location) {
                            case .success(let model): exportMachine(model)
                            case .failure(let error): MacKitUtil.alertWarn(title: "Export failed", message: error)
                            }
                        }
                        .disabled(portabilityOperation != nil || VMRunningRegistry.shared.isRunning(rootPath: workspace.location))
                        if workspace.profile == .macOS {
                            Button("Start in Recovery") { coordinator.open(workspace, recoveryMode: true) }
                        }
                    }
                    if !VMRunningRegistry.shared.isRunning(rootPath: workspace.location) {
                        Button("Remove from Library") { manager.removeVMPath(url: workspace.location) }
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Options for \(workspace.name)")
            }
            Text(workspace.name).font(.headline).lineLimit(1)
            HStack {
                Text(workspace.profile.title).foregroundStyle(.secondary)
                Spacer()
                Text(coordinator.phase(of: workspace)).foregroundStyle(.secondary)
            }.font(.caption)
            Button("Open Workspace", systemImage: "arrow.up.right") { coordinator.open(workspace) }
                .buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(20)
        .background(.background, in: .rect(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
    }
}

struct WorkspaceCreationView: View {
    let profile: WorkspaceProfile?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if let profile {
            if profile == .omarchy { OmarchyWorkspaceCreationView() }
            else { VMCreateStepperGuideView(initialProfile: profile) }
        } else {
            VStack(spacing: 20) {
                Text("Create a workspace").font(.largeTitle.weight(.semibold))
                Text("Choose the world you want to work in.").foregroundStyle(.secondary)
                ForEach(WorkspaceProfile.allCases, id: \.self) { profile in
                    Button(profile.title, systemImage: profile.symbol) { openWindow(id: "create-workspace", value: profile) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
        }
    }
}

struct OmarchyWorkspaceCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Omarchy"
    @State private var cpuCount = min(4, ProcessInfo.processInfo.activeProcessorCount)
    @State private var memoryGB = max(4, min(8, Int(ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024 * 1_024)) / 2))
    @State private var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("RiftVM Virtual Machines")
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Label("Create Omarchy", systemImage: "terminal").font(.largeTitle.weight(.semibold))
            Text("An independent Linux desktop, with its own account and disk.").foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name)
                Stepper("CPUs: \(cpuCount)", value: $cpuCount, in: 2...max(2, ProcessInfo.processInfo.activeProcessorCount))
                Stepper("Memory: \(memoryGB) GB", value: $memoryGB, in: 4...max(4, Int(ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024 * 1_024)) - 2))
                LabeledContent("Disk capacity", value: "64 GB · grows as you use it")
                LabeledContent("Location") {
                    Text(directory.path).lineLimit(1).truncationMode(.middle)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url { directory = url }
                    }
                }
            }.formStyle(.grouped)
            Text("RiftVM downloads and verifies the factory image before installing. Your Mac folders are not shared automatically.")
                .font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Continue") { create() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(36).frame(minWidth: 650, minHeight: 430)
    }

    private func create() {
        do {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
                throw VMOSError.regularFailure("Enter a valid workspace name without slashes or colons.")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let root = directory.appendingPathComponent(name + ".riftvm", isDirectory: true)
            guard !FileManager.default.fileExists(atPath: root.path) else { throw VMOSError.regularFailure("A workspace with this name already exists.") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try WorkspaceResources(cpuCount: cpuCount, memoryBytes: UInt64(memoryGB) * 1_024 * 1_024 * 1_024).write(to: root)
            let record = try sharedAppConfigManager.register(url: root, profile: .omarchy)
            WorkspaceCoordinator.shared.open(record)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct WorkspaceMenu: View {
    @Environment(\.openWindow) private var openWindow
    @State private var manager = sharedAppConfigManager
    var body: some View {
        if let launch = HeadlessLaunchConfiguration.current {
            Button("Open \(launch.machineURL.deletingPathExtension().lastPathComponent)", systemImage: "macwindow") {
                WorkspaceCoordinator.shared.reopenCommandLineWindow(at: launch.machineURL)
            }
            Divider()
        } else {
            Button("Workspaces", systemImage: "square.grid.2x2") { openWindow(id: "control-center") }
            Button("New Workspace…", systemImage: "plus") { openWindow(id: "create-machine-guide") }
            Divider()
            ForEach(manager.workspaces) { workspace in
                Button {
                    WorkspaceCoordinator.shared.open(workspace)
                } label: {
                    Label("\(workspace.name) — \(WorkspaceCoordinator.shared.phase(of: workspace))", systemImage: workspace.profile.symbol)
                }
            }
            if manager.workspaces.isEmpty { Text("No workspaces yet") }
            Divider()
        }
        SettingsLink()
        Button("Quit RiftVM") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
