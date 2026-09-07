//
//  VMModelFieldAudioDevice.swift
//  RiftVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation
import AVFoundation
import Virtualization

#if arch(arm64)
struct VMModelFieldAudioDevice: Decodable, Encodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case InputOutputStream, InputStream, OutputStream
        var id: Self { self }
        var usesMicrophone: Bool { self != .OutputStream }

        var displayName: String {
            switch self {
            case .InputOutputStream: "Microphone & Speakers"
            case .InputStream: "Microphone"
            case .OutputStream: "Speakers"
            }
        }

        var systemImage: String {
            switch self {
            case .InputOutputStream: "waveform"
            case .InputStream: "mic"
            case .OutputStream: "speaker.wave.2"
            }
        }
    }
    let type: DeviceType
    
    var description: String {
        return type.displayName
    }
    
    static func `default`() -> VMModelFieldAudioDevice {
        return VMModelFieldAudioDevice(type: .OutputStream)
    }
    
    static func createConfigurations(
        _ devices: [Self],
        microphoneAuthorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    ) -> VMOSResult<[VZAudioDeviceConfiguration], String> {
        guard !devices.contains(where: { $0.type.usesMicrophone }) || microphoneAuthorization == .authorized else {
            return .failure("This workspace uses the Mac microphone, but RiftVM does not have microphone permission. Open workspace Settings → Manage Audio to allow access or remove the microphone device, then start the workspace again.")
        }
        return .success(devices.map { $0.createConfiguration() })
    }

    func createConfiguration() -> VZAudioDeviceConfiguration {
        if type == .InputStream {
            let audioConfiguration = VZVirtioSoundDeviceConfiguration()
            let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
            inputStream.source = VZHostAudioInputStreamSource()
            audioConfiguration.streams = [inputStream]
            return audioConfiguration
        }
        
        if type == .OutputStream {
            let audioConfiguration = VZVirtioSoundDeviceConfiguration()
            let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
            outputStream.sink = VZHostAudioOutputStreamSink()
            audioConfiguration.streams = [outputStream]
            return audioConfiguration
        }
        
        let audioConfiguration = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        audioConfiguration.streams = [inputStream, outputStream]
        return audioConfiguration
    }
}

#endif
