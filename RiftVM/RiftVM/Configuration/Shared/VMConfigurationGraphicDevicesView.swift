//
//  VMConfigurationGraphicsDevicesView.swift
//  RiftVM
//
//  Created by everettjf on 2022/9/29.
//

import SwiftUI

#if arch(arm64)
struct VMConfigurationGraphicDevicesView: View {
    
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @State private var showingEditView = false
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationGraphicDevicesEditView()
            }
    }
    
    var content: some View {
        
        LabeledContent("Display") {
            VStack(alignment: .trailing, spacing: 10) {
                ForEach(configData.graphicDevices) { item in
                    Label(item.data.description, systemImage: "display")
                }
                Button("Manage Displays…", systemImage: "slider.horizontal.3") { showingEditView = true }
                    .accessibilityHint("Configure guest display type and resolution")
            }
        }
    }
}

struct VMGraphicsBackendPicker: View {
    @Binding var selection: VMLinuxGraphicsBackend
    var restriction: String? = nil

    var body: some View {
        Picker("Graphics Backend", selection: $selection) {
            ForEach(VMLinuxGraphicsBackend.allCases, id: \.self) { backend in
                Text(backend.displayName).tag(backend)
            }
        }
        .pickerStyle(.radioGroup)
        .disabled(restriction != nil)
        .accessibilityIdentifier("graphics-backend-picker")
        Text(restriction ?? (selection == .customVirGL
            ? "Accelerated Linux 3D through VirGL and ANGLE Metal. Requires compatible guest drivers and the RiftVM Guest Agent. Saved machine state is unavailable."
            : "Apple's native Virtio display for Linux compatibility and installation. Linux 3D may use software rendering."))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct OmarchyGraphicsSettingsView: View {
    let workspace: RiftWorkspaceRecord
    @Environment(\.dismiss) private var dismiss
    @State private var selection: VMLinuxGraphicsBackend = .customVirGL
    @State private var original: VMLinuxGraphicsBackend = .customVirGL
    @State private var loaded = false
    @State private var error: String?
    @State private var revision = UUID()

    private var layout: VMOmarchyWorkspaceLayout {
        VMOmarchyWorkspaceLayout(applicationSupportRoot: workspace.bundleURL)
    }
    private var restriction: String? {
        _ = revision
        return VMLinuxGraphicsBackend.changeRestriction(
            isRunning: VMRunningRegistry.shared.isRunning(rootPath: workspace.bundleURL),
            hasSavedState: FileManager.default.fileExists(atPath: workspace.bundleURL.appendingPathComponent("MachineState.vzvmsave").path)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    VMGraphicsBackendPicker(selection: $selection, restriction: restriction)
                    LabeledContent("Configured Backend", value: original.displayName)
                } header: { Label("Display", systemImage: "display") }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Text("Changes apply on the next cold boot. No automatic fallback.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!loaded || restriction != nil)
            }.padding(16)
        }
        .frame(width: 620, height: 340)
        .task {
            guard !loaded else { return }
            do {
                original = try VMOmarchyWorkspaceManager(layout: layout).metadata().effectiveGraphicsBackend
                selection = original
                loaded = true
            } catch { self.error = error.localizedDescription }
        }
        .onReceive(NotificationCenter.default.publisher(for: .riftVMRunStateDidChange)) { _ in revision = UUID() }
        .alert("Settings Could Not Be Saved", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() {
        do {
            try VMRunningRegistry.shared.withStoppedMachine(rootPath: workspace.bundleURL) {
                if let restriction = VMLinuxGraphicsBackend.changeRestriction(isRunning: false,
                    hasSavedState: FileManager.default.fileExists(atPath: workspace.bundleURL.appendingPathComponent("MachineState.vzvmsave").path)) {
                    throw VMOSError.regularFailure(restriction)
                }
                var metadata = try VMOmarchyWorkspaceManager(layout: layout).metadata()
                metadata.graphicsBackend = selection
                try JSONEncoder().encode(metadata).write(to: layout.configuration, options: .atomic)
            }
            NotificationCenter.default.post(name: .riftvmConfigurationSaved, object: workspace.bundleURL)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct VMConfigurationGraphicDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            Section("Section") {
                VMConfigurationGraphicDevicesView()
            }
        }
        .environment(VMConfigurationViewStateObject())
    }
}


#endif
