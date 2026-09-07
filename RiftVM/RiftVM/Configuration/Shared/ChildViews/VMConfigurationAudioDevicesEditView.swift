//
//  VMConfigurationAudioDevicesEditView.swift
//  RiftVM
//
//  Created by everettjf on 2022/9/30.
//

import SwiftUI
import AVFoundation
import AppKit

#if arch(arm64)
struct VMConfigurationAudioDevicesEditView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    
    @Environment(\.dismiss) private var dismiss
    
    @State private var inputType: VMModelFieldAudioDevice.DeviceType = .OutputStream
    @State private var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var isRequestingPermission = false
    @State private var showsPermissionNotice = false
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("New Audio Device") {
                    Picker("Access", selection: $inputType) {
                        ForEach(VMModelFieldAudioDevice.DeviceType.allCases) { item in
                            Label(item.displayName, systemImage: item.systemImage).tag(item)
                        }
                    }
                    Text("Speakers are enabled by default. Adding a microphone requires your permission and takes effect the next time this workspace starts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Add Audio Device", systemImage: "plus") { addDevice() }
                        .disabled(isRequestingPermission)
                    if configData.audioDevices.contains(where: { $0.data.type.usesMicrophone }),
                       microphoneAuthorization != .authorized {
                        Button("Allow Microphone Access…") { requestMicrophoneAccess {} }
                            .disabled(isRequestingPermission)
                    }
                }
                Section("Current Devices") {
                    ForEach(configData.audioDevices) { item in
                        HStack {
                            Label(item.data.description, systemImage: item.data.type.systemImage)
                            Spacer()
                            Button(role: .destructive) { configData.audioDevices.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(item.data.description)")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 380)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio) }
        }
        .alert("Microphone Access Required", isPresented: $showsPermissionNotice) {
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow RiftVM under Privacy & Security → Microphone, then try again. You can also use speakers without microphone access.")
        }
    }
    
    
    private func addDevice() {
        let type = inputType
        let append = {
            configData.audioDevices.append(VMModelFieldAudioDeviceItemModel(data: .init(type: type)))
        }
        if type.usesMicrophone { requestMicrophoneAccess(then: append) } else { append() }
    }
    private func requestMicrophoneAccess(then completion: @escaping () -> Void) {
        guard !isRequestingPermission else { return }
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        switch microphoneAuthorization {
        case .authorized: completion()
        case .notDetermined:
            isRequestingPermission = true
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    isRequestingPermission = false
                    microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
                    if granted { completion() } else { showsPermissionNotice = true }
                }
            }
        default: showsPermissionNotice = true
        }
    }

}

struct VMConfigurationAudioDevicesEditView_Previews: PreviewProvider {
    static var previews: some View {
        VMConfigurationAudioDevicesEditView()
            .environment(VMConfigurationViewStateObject())
            .frame(height: 600)
    }
}


#endif
