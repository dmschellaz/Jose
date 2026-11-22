import SwiftUI

@main
struct RedlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.isRecording ? "record.circle.fill" : "pencil.and.scribble")
        }
        Settings {
            SettingsView(settings: delegate.model.settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
    }
}
