import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var keyDraft = ""

    var body: some View {
        Form {
            Section("Claude API") {
                SecureField(settings.hasAPIKey ? "Key saved. Paste a new one to replace it" : "Paste your API key", text: $keyDraft)
                    .onSubmit { settings.setAPIKey(keyDraft); keyDraft = "" }
                HStack {
                    Button("Save Key") { settings.setAPIKey(keyDraft); keyDraft = "" }.disabled(keyDraft.isEmpty)
                    Button("Remove Key", role: .destructive) { settings.setAPIKey("") }.disabled(!settings.hasAPIKey)
                }
                Picker("Report model", selection: $settings.reportModel) {
                    ForEach(AppSettings.reportModels, id: \.self) { Text($0) }
                }
                Text("Without a key, sessions still save screenshots and the transcript, with no AI write-up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                LabeledContent("Folder", value: (settings.outputRoot.path as NSString).abbreviatingWithTildeInPath)
                Button("Choose…") { chooseFolder() }
            }
            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Start / stop session", name: .toggleSession)
                KeyboardShortcuts.Recorder("Mark moment", name: .markMoment)
                Text("Hold ⌥ on its own to draw on screen.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { NSApp.activate() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.outputRoot
        if panel.runModal() == .OK, let url = panel.url { settings.outputRoot = url }
    }
}
