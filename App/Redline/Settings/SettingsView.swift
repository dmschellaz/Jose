import AVFoundation
import KeyboardShortcuts
import RedlineCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var keyDraft = ""
    @State private var saveFailed = false
    @State private var voices = VoiceService.voices()

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
                    ForEach(AppSettings.reportModels, id: \.self) { Text(Pricing.displayName($0)) }
                }
                Text("Without a key, sessions still save screenshots and the transcript, with no AI write-up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Live mode") {
                Picker("Live model", selection: $settings.liveModel) {
                    ForEach(AppSettings.liveModels, id: \.self) { Text(Self.priceLabel($0)).tag($0) }
                }
                Text("Live sends a screenshot of your screen to Claude after each sentence, roughly 2–3k tokens each.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Chatty mode") {
                Picker("Voice", selection: $settings.voiceIdentifier) {
                    Text("System default").tag(String?.none)
                    ForEach(voices, id: \.identifier) { voice in
                        Text(Self.voiceLabel(voice)).tag(String?.some(voice.identifier))
                    }
                }
                Button("Preview") { VoiceService.preview(voiceIdentifier: settings.voiceIdentifier) }
                Text("Chatty is Live plus a voice. It speaks a short line only when it's unsure or you change topic, and may ask which thing you mean. It uses the live model above. More voices: System Settings → Accessibility → Spoken Content.")
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

    /// "Haiku 5.5 · $0.10 in / $0.50 out per M tokens".
    private static func priceLabel(_ model: String) -> String {
        let name = Pricing.displayName(model)
        guard let input = Pricing.cost(model: model, tokens: TokenUsage(input: 1_000_000)),
              let output = Pricing.cost(model: model, tokens: TokenUsage(output: 1_000_000)) else { return name }
        return "\(name) · \(dollars(input)) in / \(dollars(output)) out per M tokens"
    }

    /// "Samantha · en-US (Enhanced)".
    private static func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        let base = "\(voice.name) · \(voice.language)"
        switch voice.quality {
        case .premium: return base + " (Premium)"
        case .enhanced: return base + " (Enhanced)"
        default: return base
        }
    }

    private static func dollars(_ usd: Double) -> String {
        usd == usd.rounded() ? String(format: "$%.0f", usd) : String(format: "$%.2f", usd)
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
