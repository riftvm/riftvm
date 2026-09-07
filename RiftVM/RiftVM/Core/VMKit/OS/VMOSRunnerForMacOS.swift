//
//  VMOSRunnerForMacOS.swift
//  RiftVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import CryptoKit
import Virtualization

#if arch(arm64)

class VMOSRunnerForMacOS : VMOSRunner {
    
    
    func createConfiguration(
        model: VMModel,
        graphicsBackend: (any VMGraphicsBackend)? = nil
    ) -> VMOSResult<VZVirtualMachineConfiguration, String> {
        
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()
        VMConfigurationIdentity.apply(machineName: model.config.name, to: virtualMachineConfiguration)

        // platform
        let platformResult = createMacPlatformConfiguration(model: model)
        switch platformResult {
        case .failure(let error):
            return .failure(error)
        case .success(let macPlatform):
            virtualMachineConfiguration.platform = macPlatform
        }
        
        // cpu
        virtualMachineConfiguration.cpuCount = model.config.cpu.count
        
        // memory
        virtualMachineConfiguration.memorySize = model.config.memory.size
        
        // bootLoader
        virtualMachineConfiguration.bootLoader = VZMacOSBootLoader()
        
        // graphicsDevices
        virtualMachineConfiguration.graphicsDevices = model.config.graphicsDevices.map({$0.createConfiguration()})
        
        // storageDevices
        virtualMachineConfiguration.storageDevices = []
        for item in model.config.storageDevices {
            let result = item.createConfiguration(rootPath: model.rootPath)
            switch result {
            case .failure(let error):
                return .failure(error)
            case .success(let configItem):
                virtualMachineConfiguration.storageDevices.append(configItem)
            }
        }
        
        // networkDevices
        switch VMModelFieldNetworkDevice.createConfigurations(model.config.networkDevices) {
        case .success(let devices):
            guard let identity = try? Data(contentsOf: model.machineIdentifierURL) else {
                return .failure("Could not read the machine identity for network configuration.")
            }
            for (index, device) in devices.enumerated() {
                var input = identity
                input.append(Data("riftvm-network-\(index)".utf8))
                var bytes = Array(SHA256.hash(data: input).prefix(6))
                bytes[0] = (bytes[0] & 0xfc) | 0x02
                let value = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                guard let address = VZMACAddress(string: value) else {
                    return .failure("Could not create the persistent network address.")
                }
                device.macAddress = address
            }
            virtualMachineConfiguration.networkDevices = devices
        case .failure(let error): return .failure(error)
        }
        
        // pointingDevices
        virtualMachineConfiguration.pointingDevices = model.config.pointingDevices.map({$0.createConfiguration()})
        
        // audioDevices
        virtualMachineConfiguration.audioDevices = model.config.audioDevices.map({$0.createConfiguration()})
        
        // keyboards
        virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]

        VMUSBControllerSupport.addEmptyXHCIController(to: virtualMachineConfiguration)

        // directorySharingDevices
        virtualMachineConfiguration.directorySharingDevices = [
            VMModelFieldDirectorySharingDevice.createRuntimeConfiguration(
                model.config.directorySharingDevices,
                osType: .macOS
            )
        ]
        
        
        // Validate
        do {
            try virtualMachineConfiguration.validate()
        } catch {
            return .failure("failed to validate : \(error)")
        }
        
        return .success(virtualMachineConfiguration)
        
    }
    
    
    private func createMacPlatformConfiguration(model: VMModel) -> VMOSResult<VZMacPlatformConfiguration, String> {
        
        let macPlatform = VZMacPlatformConfiguration()
        
        let auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: model.auxiliaryStorageURL)
        macPlatform.auxiliaryStorage = auxiliaryStorage
        
        // Retrieve the hardware model; you should save this value to disk
        // during installation.
        guard let hardwareModelData = try? Data(contentsOf: model.hardwareModelURL) else {
            return .failure("Failed to retrieve hardware model data.")
        }
        
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            return .failure("Failed to create hardware model.")
        }
        
        if !hardwareModel.isSupported {
            return .failure("The hardware model isn't supported on the current host")
        }
        macPlatform.hardwareModel = hardwareModel
        
        // Retrieve the machine identifier; you should save this value to disk
        // during installation.
        guard let machineIdentifierData = try? Data(contentsOf: model.machineIdentifierURL) else {
            return .failure("Failed to retrieve machine identifier data.")
        }
        
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            return .failure("Failed to create machine identifier.")
        }
        macPlatform.machineIdentifier = machineIdentifier
        
        return .success(macPlatform)
    }

}

#endif
