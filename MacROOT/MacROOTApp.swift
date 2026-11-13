import SwiftUI

@main
struct MacROOTApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView()
                .frame(width: 640, height: 580)
        }
    }
}
