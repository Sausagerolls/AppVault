import AppKit
import SwiftUI

@main
struct AppVaultApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Writing to a tar process that exited must return an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup("AppVault") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.transfers)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh") { Task { await model.refreshAll() } }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
        }
    }
}
