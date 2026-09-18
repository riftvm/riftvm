import AppKit
import Foundation
import SwiftUI

#if arch(arm64)
/// Actions the single window offers for the Omarchy it is showing.
struct WorkspaceWindowActions {
    var remove: () -> Void
}

/// The app's one window. It prepares the workspace when there is none and drives
/// the workspace when there is; there is no second window and no workspace list.
@MainActor
@Observable
final class WorkspaceHomeModel {
    enum State: Equatable {
        case loading
        case preparing
        case workspace(ActiveWorkspaceRecord)
    }

    private(set) var state: State = .loading
    var errorMessage: String?
    private(set) var session = WorkspaceCreationSession()

    private let store: ActiveWorkspaceStore

    init(store: ActiveWorkspaceStore = .standard) {
        self.store = store
    }

    func load() {
        do {
            if let record = try store.current() {
                state = .workspace(record)
            } else {
                state = .preparing
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            state = .preparing
        }
    }

    /// The workspace bundle exists now, so the window switches from preparing
    /// to driving it.
    func workspaceWasCreated() {
        load()
    }

    /// Records the visit without republishing state, so the running view is not
    /// rebuilt just because a timestamp changed.
    func markOpened() {
        _ = try? store.markOpened()
    }

    func remove() {
        guard case .workspace(let record) = state else { return }
        do {
            try RiftWorkspaceBundleRemoval.moveToTrashIfPresent(record.bundleURL)
            try store.clear()
            session = WorkspaceCreationSession()
            WorkspaceCreationStore.shared.sessions.removeAll()
            state = .preparing
        } catch { errorMessage = error.localizedDescription }
    }
}

struct WorkspaceHomeView: View {
    @State private var model = WorkspaceHomeModel()

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                ProgressView("Opening Omarchy…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .preparing:
                WorkspaceCreationView(session: model.session, onCreated: model.workspaceWasCreated)
            case .workspace(let record):
                WorkspaceRuntimeView(
                    record: record,
                    remove: model.remove,
                    markOpened: model.markOpened
                )
            }
        }
        .task { model.load() }
        .alert("RiftVM", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

/// The prepared workspace, driven by the Omarchy runtime.
private struct WorkspaceRuntimeView: View {
    let record: ActiveWorkspaceRecord
    let remove: () -> Void
    let markOpened: () -> Void

    var body: some View {
        OmarchyRootView(
            profile: .production,
            workspaceManager: VMOmarchyWorkspaceManager(
                layout: VMOmarchyWorkspaceLayout(applicationSupportRoot: record.bundleURL)
            ),
            workspace: record,
            actions: WorkspaceWindowActions(remove: remove)
        )
        .onAppear { markOpened() }
    }
}

#Preview { WorkspaceHomeView() }
#endif
