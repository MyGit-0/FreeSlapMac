import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: SlapEngine

    var body: some View {
        Text("Slaps: \(engine.slapCount)")
        Text(engine.lastEvent).font(.caption).foregroundStyle(.secondary)
        Divider()

        Text("Helper: \(engine.helperStatusText)")
            .font(.caption)

        Button(engine.running ? "Pause Detection" : "Start Detection") {
            engine.toggleRunning()
        }

        Button("Rage Quit 🧘") {
            engine.rageQuit()
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])

        Divider()
        SettingsLink { Text("Settings…") }.keyboardShortcut(",", modifiers: .command)
        Button("Reveal Logs") { engine.openLogFolder() }
        Button("Quit FreeSlapMac") { NSApp.terminate(nil) }.keyboardShortcut("q", modifiers: .command)
    }
}
