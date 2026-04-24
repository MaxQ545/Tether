import SwiftUI

@main
struct TetherApp: App {
    @State private var store = ConfigStore.shared

    init() {
        // Kick the engine off right as the process boots so enabled projects
        // start their watchers/timers before the first menu click.
        Task { @MainActor in
            SyncEngine.shared.bootstrap()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Edit Project", id: "project-editor", for: UUID.self) { $projectID in
            ProjectEditorView(projectID: projectID)
                .environment(store)
                .frame(minWidth: 560, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
    }
}
