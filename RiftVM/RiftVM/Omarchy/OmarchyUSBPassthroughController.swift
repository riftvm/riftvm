import AccessoryAccess
import Foundation
@preconcurrency import Virtualization

/// Connects only accessories the person has assigned to RiftVM in macOS's
/// Accessory Access menu. Virtualization owns the exclusive device capture.
@MainActor
final class OmarchyUSBPassthroughController: NSObject, AAUSBAccessoryListener,
    VZUSBController.Delegate {
    private weak var machine: VZVirtualMachine?
    private var controller: VZUSBController?
    private let issueChanged: (String?) -> Void
    private var active = false
    private var registered = false
    private var assigned: [UInt64: AAUSBAccessory] = [:]
    private var assignmentTokens: [UInt64: UUID] = [:]
    private var attaching: Set<UInt64> = []
    private var detaching: Set<UInt64> = []
    private var attached: [UInt64: VZUSBPassthroughDevice] = [:]

    init(issueChanged: @escaping (String?) -> Void) {
        self.issueChanged = issueChanged
    }

    func start(for machine: VZVirtualMachine) {
        guard !active else { return }
        // A contributor can remove the restricted entitlement for a local
        // Personal Team build; keep the rest of the VM usable in that case.
        guard VMHostCapability.accessoryAccess.isGranted else { return }
        guard let controller = machine.usbControllers.first else {
            report("USB passthrough is unavailable: Omarchy has no USB controller.")
            return
        }
        self.machine = machine
        self.controller = controller
        controller.delegate = self
        active = true
        issueChanged(nil)

        // An empty criteria list offers any supported USB accessory through
        // macOS's menu. The listener only receives devices assigned by the user.
        AAUSBAccessoryManager.shared.registerListener(self, matchingCriteria: []) { [weak self] accessories, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    if self.active { self.report("USB accessory access could not start: \(error.localizedDescription)") }
                    return
                }
                self.registered = true
                guard self.active else {
                    self.unregister()
                    return
                }
                for accessory in accessories { self.connect(accessory) }
            }
        }
    }

    func attachAssignedAccessories() {
        for accessory in assigned.values { attach(accessory) }
    }

    func stop() {
        active = false
        assigned.removeAll()
        assignmentTokens.removeAll()
        unregister()
        controller?.delegate = nil
        if let controller {
            for (id, device) in attached where device.usbController === controller {
                detach(device, id: id, from: controller)
            }
        }
        attached.removeAll()
        // An in-flight attach checks active in its completion and detaches
        // itself if the VM has already been stopped or replaced.
        attaching.removeAll()
        controller = nil
        machine = nil
        issueChanged(nil)
    }

    private func unregister() {
        guard registered else { return }
        registered = false
        AAUSBAccessoryManager.shared.unregisterListener(self) {}
    }

    nonisolated func usbAccessoryDidConnect(_ usbAccessory: AAUSBAccessory) {
        DispatchQueue.main.async { [weak self] in self?.connect(usbAccessory) }
    }

    nonisolated func usbAccessoryDidDisconnect(_ usbAccessory: AAUSBAccessory) {
        DispatchQueue.main.async { [weak self] in self?.disconnect(usbAccessory) }
    }

    nonisolated func usbController(
        _ usbController: VZUSBController,
        usbPassthroughDeviceDidDisconnect device: VZUSBPassthroughDevice
    ) {
        let disconnectedUUID = device.uuid
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller != nil else { return }
            if let id = self.attached.first(where: { $0.value.uuid == disconnectedUUID })?.key {
                self.attached.removeValue(forKey: id)
            }
        }
    }

    private func connect(_ accessory: AAUSBAccessory) {
        guard active else { return }
        let id = accessory.registryID
        if assigned[id] !== accessory {
            assigned[id] = accessory
            assignmentTokens[id] = UUID()
        }
        attach(accessory)
    }

    private func disconnect(_ accessory: AAUSBAccessory) {
        let id = accessory.registryID
        assigned.removeValue(forKey: id)
        assignmentTokens.removeValue(forKey: id)
        guard let controller, let device = attached.removeValue(forKey: id),
              device.usbController === controller else { return }
        detach(device, id: id, from: controller)
    }

    private func attach(_ accessory: AAUSBAccessory) {
        let id = accessory.registryID
        guard active, machine?.state == .running, let controller,
              attached[id] == nil, !attaching.contains(id), !detaching.contains(id),
              let assignmentToken = assignmentTokens[id] else { return }
        attaching.insert(id)
        do {
            let configuration = VZUSBPassthroughDeviceConfiguration(device: accessory)
            let device = try VZUSBPassthroughDevice(configuration: configuration)
            controller.attach(device: device) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else {
                        if error == nil { controller.detach(device: device) { _ in } }
                        return
                    }
                    self.attaching.remove(id)
                    if let error {
                        if self.active && self.assigned[id] != nil {
                            self.report("USB device could not be attached to Omarchy: \(error.localizedDescription)")
                        }
                        return
                    }
                    guard self.active, self.assignmentTokens[id] == assignmentToken,
                          self.controller === controller else {
                        self.detach(device, id: id, from: controller)
                        return
                    }
                    self.attached[id] = device
                    self.issueChanged(nil)
                    RiftVMLog.info("USB accessory \(id) attached to Omarchy")
                }
            }
        } catch {
            attaching.remove(id)
            report("USB device could not be initialized: \(error.localizedDescription)")
        }
    }

    private func detach(_ device: VZUSBPassthroughDevice, id: UInt64, from controller: VZUSBController) {
        guard device.usbController === controller else {
            if let replacement = assigned[id] { attach(replacement) }
            return
        }
        detaching.insert(id)
        controller.detach(device: device) { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    RiftVMLog.error("USB device detach failed: \(error.localizedDescription)")
                }
                guard let self else { return }
                self.detaching.remove(id)
                if let replacement = self.assigned[id] { self.attach(replacement) }
            }
        }
    }

    private func report(_ message: String) {
        RiftVMLog.error(message)
        issueChanged(message)
    }
}
