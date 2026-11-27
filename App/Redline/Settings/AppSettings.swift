import Foundation
import Observation
import RedlineCore

@MainActor @Observable
final class AppSettings {
    static let reportModels = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"]
    static let liveModels = ["claude-haiku-5-5", "claude-sonnet-5-5"]
    /// Modes the user can pick.
    static let availableModes: [SessionMode] = [.manual, .live, .chatty]
    private let defaults = UserDefaults.standard

    var outputRoot: URL {
        didSet { defaults.set(outputRoot.path, forKey: "outputRoot") }
    }
    var reportModel: String {
        didSet { defaults.set(reportModel, forKey: "reportModel") }
    }
    var lastSessionPath: String? {
        didSet { defaults.set(lastSessionPath, forKey: "lastSessionPath") }
    }
    /// Copy the whole write-up (screenshots pasted separately) instead of a path, for a Claude
    /// session running on another computer.
    var pasteForOtherComputer: Bool {
        didSet { defaults.set(pasteForOtherComputer, forKey: "pasteForOtherComputer") }
    }
    var sessionMode: SessionMode {
        didSet { defaults.set(sessionMode.rawValue, forKey: "sessionMode") }
    }
    /// The model Live mode asks after each sentence.
    var liveModel: String {
        didSet { defaults.set(liveModel, forKey: "liveModel") }
    }
    /// Chatty's voice (an AVSpeechSynthesisVoice identifier); nil uses the system default.
    var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: "voiceIdentifier") }
    }
    private(set) var hasAPIKey: Bool

    init() {
        outputRoot = defaults.string(forKey: "outputRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Feedback", directoryHint: .isDirectory)
        let storedModel = defaults.string(forKey: "reportModel")
        reportModel = storedModel.flatMap { Self.reportModels.contains($0) ? $0 : nil } ?? Self.reportModels[0]
        lastSessionPath = defaults.string(forKey: "lastSessionPath")
        pasteForOtherComputer = defaults.bool(forKey: "pasteForOtherComputer")
        let storedMode = defaults.string(forKey: "sessionMode").flatMap(SessionMode.init(rawValue:))
        sessionMode = storedMode.flatMap { Self.availableModes.contains($0) ? $0 : nil } ?? .manual
        let storedLive = defaults.string(forKey: "liveModel")
        liveModel = storedLive.flatMap { Self.liveModels.contains($0) ? $0 : nil } ?? Self.liveModels[0]
        // Keep the saved voice only if the picker can still offer it; otherwise use the system default.
        let storedVoice = defaults.string(forKey: "voiceIdentifier")
        voiceIdentifier = storedVoice.flatMap { id in VoiceService.voices().contains { $0.identifier == id } ? id : nil }
        hasAPIKey = KeychainStore.load() != nil
    }

    @discardableResult
    func setAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            try KeychainStore.save(trimmed)
        } catch {
            return false
        }
        hasAPIKey = KeychainStore.load() != nil
        return true
    }

    func removeAPIKey() {
        KeychainStore.delete()
        hasAPIKey = KeychainStore.load() != nil
    }

    func apiKey() -> String? { KeychainStore.load() }
}
