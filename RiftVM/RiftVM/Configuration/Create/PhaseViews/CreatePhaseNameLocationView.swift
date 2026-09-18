//
//  CreatePhaseNameLocationView.swift
//  RiftVM
//
//  Created by everettjf on 2026/8/18.
//

import SwiftUI

#if arch(arm64)

/// Where Omarchy is stored, and the name it carries.
///
/// There is one Omarchy and no name to choose: the folder, the display name, and
/// the guest's own name are all "Omarchy". This handler still owns the storage
/// decision, because a 64 GB machine may need to live off the system volume.
class CreatePhaseNameLocationViewHandler: VMCreateStepperGuidePhaseHandler {
    static let workspaceName = "Omarchy"

    // New machines go in the hidden ~/.riftvm folder, so a 64 GB virtual machine
    // does not sit in the visible home folder. A custom choice applies only to
    // this machine.
    static func defaultStorageDirectory() -> URL {
        ActiveWorkspaceLocation.defaultBaseDirectory()
    }

    static func bundlePath(baseDirectory: String, name: String = workspaceName) -> String {
        let baseURL = URL(filePath: baseDirectory)
        return baseURL.appending(path: "\(name).riftvm").path(percentEncoded: false)
    }

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        context.configData.name = Self.workspaceName

        if context.formData.baseDirectory.isEmpty {
            return .failure("Choose where Omarchy should be stored.")
        }

        let rootPath = Self.bundlePath(baseDirectory: context.formData.baseDirectory)
        context.formData.rootPath = rootPath

        if FileManager.default.fileExists(atPath: rootPath) {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
            if items.count >= 2 {
                return .failure("Omarchy already exists at \(rootPath). Choose another location, or remove that copy first.")
            }
        }

        // make sure the base directory exists (e.g. the default ~/.riftvm)
        let baseDir = URL(filePath: context.formData.baseDirectory)
        if !FileManager.default.fileExists(atPath: baseDir.path(percentEncoded: false)) {
            do {
                try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            } catch {
                return .failure("Unable to create directory \(baseDir.path(percentEncoded: false)) : \(error.localizedDescription)")
            }
        }

        return .success
    }

    func onStepMovedIn(context: VMCreateStepperGuidePhaseContext) async -> VMOSResultVoid {
        await MainActor.run {
            if context.formData.baseDirectory.isEmpty {
                context.formData.baseDirectory = Self.defaultStorageDirectory().path(percentEncoded: false)
            }
            context.configData.name = Self.workspaceName
            context.formData.rootPath = Self.bundlePath(baseDirectory: context.formData.baseDirectory)
        }
        return .success
    }
}

#endif
