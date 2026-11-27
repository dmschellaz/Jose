import AVFoundation
import RedlineCore

/// Chatty's voice: speaks lines with AVSpeechSynthesizer and the built-in voice picked in Settings.
///
/// - While it speaks, the microphone gate is closed. It reopens 300 ms after the last line, so Redline's
///   voice is never transcribed.
/// - Sessions mute the Mac's output. If that mute is in place, it is lifted for the line and put back after.
/// - No barge-in: the island's "Stop talking" calls `stopTalking()`.
@MainActor
final class VoiceService: NSObject, SessionService {
    /// Called when speaking starts (true) and when the last queued line ends or is cut (false).
    var onSpeakingChanged: (@MainActor (Bool) -> Void)?
    /// AVSpeechSynthesisVoice identifier; nil uses the system default voice for the current language.
    var voiceIdentifier: String?
    private(set) var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private let gate: MicGate
    /// Utterances handed to the synthesizer that haven't finished or been cancelled yet.
    private var pending: Set<ObjectIdentifier> = []
    /// True when speaking lifted the session's mute, so it is put back afterwards.
    private var liftedMute = false
    private var active = false

    init(gate: MicGate) {
        self.gate = gate
        super.init()
        synthesizer.delegate = self
    }

    func start(context: SessionContext) async throws {
        active = context.mode == .chatty
    }

    func stop() async {
        active = false
        cutOff(remute: false)   // AppModel restores the Mac's audio right after the session stops
    }

    func speak(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !line.isEmpty else { return }
        if !isSpeaking {
            gate.close()
            liftedMute = SystemAudio.isMutedByRedline
            if liftedMute { SystemAudio.restoreOutput() }
            isSpeaking = true
            onSpeakingChanged?(true)
        }
        let utterance = AVSpeechUtterance(string: line)
        utterance.voice = Self.voice(voiceIdentifier)
        pending.insert(ObjectIdentifier(utterance))
        synthesizer.speak(utterance)
    }

    /// "Stop talking": cuts the current line and anything queued.
    func stopTalking() {
        cutOff(remute: true)
    }

    /// Built-in voices for the current language, best quality first. Novelty and Personal Voices are left out.
    static func voices() -> [AVSpeechSynthesisVoice] {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    /// Settings' "Preview" button.
    static func preview(voiceIdentifier: String?) {
        previewSynthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: "I marked the billing card. Is that the one?")
        utterance.voice = voice(voiceIdentifier)
        previewSynthesizer.speak(utterance)
    }

    private static let previewSynthesizer = AVSpeechSynthesizer()

    private static func voice(_ identifier: String?) -> AVSpeechSynthesisVoice? {
        identifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? AVSpeechSynthesisVoice(language: nil)
    }

    fileprivate func ended(_ id: ObjectIdentifier) {
        guard pending.remove(id) != nil, pending.isEmpty else { return }
        finish(remute: true)
    }

    private func cutOff(remute: Bool) {
        pending = []
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        finish(remute: remute)
    }

    private func finish(remute: Bool) {
        guard isSpeaking else { return }
        if remute && liftedMute { SystemAudio.muteOutput() }
        liftedMute = false
        gate.open()
        isSpeaking = false
        onSpeakingChanged?(false)
    }
}

extension VoiceService: AVSpeechSynthesizerDelegate {
    // AVSpeechSynthesizer calls its delegate on its own queue. These stay nonisolated (a @MainActor method called
    // off the main thread traps in Swift 6) and hop to the main actor carrying only a Sendable id.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.ended(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.ended(id) }
    }
}
