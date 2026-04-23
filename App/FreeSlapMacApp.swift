import SwiftUI

@main
struct FreeSlapMacApp: App {
    @StateObject private var engine = SlapEngine()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
        } label: {
            Image(systemName: engine.running ? "hand.raised.fill" : "hand.raised")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(engine: engine)
                .frame(width: 620, height: 620)
        }
    }
}
