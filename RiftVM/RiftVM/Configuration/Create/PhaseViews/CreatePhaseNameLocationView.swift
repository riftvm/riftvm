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
/// There is one Omarchy, so nothing here is a choice: the folder, the display
/// name, and the guest's own name are all "Omarchy", and the disk lives in the
/// hidden ~/.riftvm folder. The handler still builds the path and refuses to
/// prepare on top of an existing machine.
class CreatePhaseNameLocationViewHandler: VMCreateStepperGuidePhaseHandler {
    static let workspaceName = "Omarchy"

    // The machine goes in the hidden ~/.riftvm folder, so a 64 GB virtual
    // machine does not sit in the visible home folder.
    static func defaultStorageDirectory() -> URL {
        ActiveWorkspaceLocation.defaultBaseDirectory()
    }

    static func bundlePath(baseDirectory: String, name: String = workspaceName) -> String {
        let baseURL = URL(filePath: baseDirectory)
        return baseURL.appending(path: "\(name).riftvm").path(percentEncoded: false)
    }

    func verifyForm(context: VMCreateStepperGuidePhaseContext) -> VMOSResultVoid {
        context.formData.baseDirectory = Self.defaultStorageDirectory().path(percentEncoded: false)

        let rootPath = Self.bundlePath(baseDirectory: context.formData.baseDirectory)
        context.formData.rootPath = rootPath

        if FileManager.default.fileExists(atPath: rootPath) {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
            if items.count >= 2 {
                return .failure("Omarchy already exists at \(rootPath). Remove it from the Omarchy menu first.")
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
            context.formData.baseDirectory = Self.defaultStorageDirectory().path(percentEncoded: false)
                context.formData.rootPath = Self.bundlePath(baseDirectory: context.formData.baseDirectory)
        }
        return .success
    }
}

#endif
