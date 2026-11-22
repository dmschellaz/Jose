import SwiftUI

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        if model.isRecording {
            Button("Stop & Write Report") { Task { await model.toggleSession() } }
            Button("Mark Moment") { model.markMoment() }
            Button("Cancel Session") { Task { await model.cancel() } }
        } else if model.isStarting {
            Button("Starting…") {}.disabled(true)
        } else {
            Button(model.isFinalizing ? "Writing report…" : "Start Feedback Session") { Task { await model.toggleSession() } }
                .disabled(model.isFinalizing)
        }
        Text("Mode: Manual. Live & Chatty arrive in later phases.")
        Divider()
        Menu("Recent Sessions") {
            let recent = model.recentSessions()
            if recent.isEmpty { Text("None yet") }
            ForEach(recent, id: \.self) { url in
                Button(url.lastPathComponent) { NSWorkspace.shared.open(url) }
            }
        }
        Button("Copy Last Write-up + Screenshots") { if let f = model.lastSessionFolder { model.copyWriteup(folder: f) } }
            .disabled(model.lastSessionFolder == nil)
        Button("Copy Last Screenshots Only") { if let f = model.lastSessionFolder { model.copyWriteup(folder: f, includeText: false) } }
            .disabled(model.lastSessionFolder == nil)
        Button("Regenerate Last Report") { Task { await model.regenerateLast() } }
            .disabled(model.lastSessionFolder == nil || model.isRecording || model.isStarting || model.isFinalizing)
        Divider()
        Button("Permissions…") { model.showOnboarding() }
        SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        #if DEBUG
        DebugMenu(model: model)
        #endif
        Divider()
        Button("Quit Redline") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
