import SwiftUI

struct MenuContent: View {
    let model: AppModel
    var body: some View {
        Button("Quit Redline") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
