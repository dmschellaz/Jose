import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var keyDraft = ""
    @State private var saveFailed = false

    var body: some View {
        Form {
            Section("Claude API") {
                SecureField(settings.hasAPIKey ? "Key saved. Paste a new one to replace it" : "Paste your API key", text: $keyDraft)
                    .onSubmit { saveDraft() }
                HStack {
                    Button("Save Key") { saveDraft() }
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove Key", role: .destructive) { settings.removeAPIKey(); saveFailed = false }.disabled(!settings.hasAPIKey)
                }
                if saveFailed {
                    Text("Couldn't save the key to Keychain.").font(.caption).foregroundStyle(.red)
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
            Section("Hand-off") {
                Picker("Claude Code runs on", selection: $settings.pasteForOtherComputer) {
                    Text("This Mac").tag(false)
                    Text("Another computer").tag(true)
                }
                Text(settings.pasteForOtherComputer
                     ? "Press ⌘V twice in the Claude chat: the first pastes the write-up, the second the screenshots."
                     : "Copies a short prompt that points Claude Code to the session folder on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
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

    private func saveDraft() {
        guard !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if settings.setAPIKey(keyDraft) {
            keyDraft = ""
            saveFailed = false
        } else {
            saveFailed = true
        }
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
