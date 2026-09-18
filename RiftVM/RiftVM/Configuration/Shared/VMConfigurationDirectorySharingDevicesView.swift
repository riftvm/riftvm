//
//  VMConfigurationDirectorySharingDevicesView.swift
//  RiftVM
//
//  Created by everettjf on 2022/10/5.
//

import SwiftUI
import UniformTypeIdentifiers

#if arch(arm64)
enum VMSharedFolderDrop {
    static func directories(from urls: [URL]) -> [URL] {
        urls.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }
}

struct VMConfigurationDirectorySharingDevicesView: View {
    @Environment(VMConfigurationViewStateObject.self) var configData
    @State private var showingEditView = false
    @State private var isDropTargeted = false
    @State private var dropFeedback: String?
    let appliesSharedFoldersImmediately: Bool

    init(appliesSharedFoldersImmediately: Bool = false) {
        self.appliesSharedFoldersImmediately = appliesSharedFoldersImmediately
    }
    
    
    var body: some View {
        content
            .sheet(isPresented: $showingEditView) {
                VMConfigurationDirectorySharingDevicesEditView(
                    appliesSharedFoldersImmediately: appliesSharedFoldersImmediately
                )
            }
    }
    
    var content: some View {
        LabeledContent("Shared Folders") {
            VStack(alignment: .trailing) {
                List(configData.directorySharingDevices) { item in
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(item.data.items.map(\.name).joined(separator: ", "))
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                            let unavailableCount = item.data.items.filter {
                                VMSharedFolderPathValidator.status(for: $0.path) != .available
                            }.count
                            if unavailableCount > 0 {
                                Label("\(unavailableCount) unavailable", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .frame(width:400)
                .overlay {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.12))
                            .overlay {
                                Label("Drop to share", systemImage: "folder.fill.badge.plus")
                                    .font(.headline)
                            }
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    addDroppedURLs(urls)
                } isTargeted: {
                    isDropTargeted = $0
                }

                if let dropFeedback {
                    Text(dropFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Spacer()
                    Button {
                        MacKitUtil.selectDirectory(title: "Choose a Folder to Share") { url in
                            guard let url else { return }
                            _ = configData.addSharedDirectory(url)
                        }
                    } label: {
                        Label("Add Shared Folder", systemImage: "folder.badge.plus")
                    }
                    .help("Choose a folder to share")

                    Button {
                        showingEditView.toggle()
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .help("Manage shared folders")
                }
            }
        }
    }

    private func addDroppedURLs(_ urls: [URL]) -> Bool {
        let directories = VMSharedFolderDrop.directories(from: urls)
        let added = directories.reduce(into: 0) { count, url in
            if configData.addSharedDirectory(url) { count += 1 }
        }
        dropFeedback = added > 0
            ? "Added \(added) shared folder\(added == 1 ? "" : "s")."
            : "Drop folders that are not already shared."
        return added > 0
    }
}

struct VMConfigurationDirectorySharingDevicesView_Previews: PreviewProvider {
    static var previews: some View {
        Form {
            VMConfigurationDirectorySharingDevicesView()
                .environment(VMConfigurationViewStateObject())
        }
        .formStyle(.grouped)
    }
}


#endif
