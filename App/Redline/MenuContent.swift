import SwiftUI

struct MenuContent: View {
    let model: AppModel
    var body: some View {
        SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        Divider()
        Button("Quit Redline") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
