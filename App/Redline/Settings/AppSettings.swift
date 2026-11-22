import Foundation
import Observation

@MainActor @Observable
final class AppSettings {
    static let reportModels = ["claude-sonnet-5-5", "claude-opus-5-5"]
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
    private(set) var hasAPIKey: Bool

    init() {
        outputRoot = defaults.string(forKey: "outputRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Feedback", directoryHint: .isDirectory)
        let storedModel = defaults.string(forKey: "reportModel")
        reportModel = storedModel.flatMap { Self.reportModels.contains($0) ? $0 : nil } ?? Self.reportModels[0]
        lastSessionPath = defaults.string(forKey: "lastSessionPath")
        pasteForOtherComputer = defaults.bool(forKey: "pasteForOtherComputer")
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
