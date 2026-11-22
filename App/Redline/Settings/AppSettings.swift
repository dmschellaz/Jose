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
    private(set) var hasAPIKey: Bool

    init() {
        outputRoot = defaults.string(forKey: "outputRoot").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Feedback", directoryHint: .isDirectory)
        reportModel = defaults.string(forKey: "reportModel") ?? Self.reportModels[0]
        lastSessionPath = defaults.string(forKey: "lastSessionPath")
        hasAPIKey = KeychainStore.load() != nil
    }

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete()
        } else {
            try? KeychainStore.save(trimmed)
        }
        hasAPIKey = KeychainStore.load() != nil
    }

    func apiKey() -> String? { KeychainStore.load() }
}
