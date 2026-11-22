import AppKit
import KeyboardShortcuts
import Observation
import RedlineCore

@MainActor @Observable
final class AppModel {
    let settings = AppSettings()
    private(set) var partialTranscript = ""
    private(set) var isStarting = false
    @ObservationIgnored private var isRegenerating = false
    @ObservationIgnored private(set) var controller: SessionController!

    @ObservationIgnored private let capture = CaptureService()
    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private let context = ContextService()
    @ObservationIgnored private let speech = SpeechService()
    @ObservationIgnored private let pill = RecordingPillController()
    @ObservationIgnored private let onboarding = OnboardingWindowController()

    var isRecording: Bool { controller.isRecording }
    var isFinalizing: Bool { controller.state == .finalizing }
    var lastSessionFolder: URL? { settings.lastSessionPath.map { URL(fileURLWithPath: $0) } }

    init() {
        let settings = self.settings
        controller = SessionController(
            capture: capture,
            services: [overlay, context, speech],   // stop order is reversed: speech flushes first
            outputRoot: { settings.outputRoot },
            reportBuilder: { Self.makeReportBuilder(settings) })
        context.onPen = { [overlay] in overlay.setPen($0) }
        speech.onPartial = { [weak self] in self?.partialTranscript = $0 }
    }

    func launch() {
        Notifier.setUp()
        KeyboardShortcuts.onKeyUp(for: .toggleSession) { [weak self] in Task { @MainActor in await self?.toggleSession() } }
        KeyboardShortcuts.onKeyUp(for: .markMoment) { [weak self] in Task { @MainActor in self?.markMoment() } }
        if !Permission.missing.isEmpty { onboarding.show() }
    }

    func toggleSession() async {
        guard !isStarting else { return }
        switch controller.state {
        case .recording: await stopSession()
        case .finalizing: return
        default: await startSession()
        }
    }

    func cancel() async {
        let wasActive = controller.isRecording || isStarting
        await controller.cancel()
        if wasActive { pill.hide() }
        partialTranscript = ""
    }

    func markMoment() {
        guard isRecording else { return }
        controller.markMoment()
        NSSound(named: "Tink")?.play()
    }

    func showOnboarding() { onboarding.show() }

    func regenerateLast() async {
        guard let url = lastSessionFolder, !isRegenerating, !isFinalizing, !isRecording else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        let folder = SessionFolder(url: url)
        do {
            let doc = try SessionStore.load(from: folder)
            let result = await Self.makeReportBuilder(settings).build(document: doc, folder: folder)
            handOff(result, folder: folder)
        } catch {
            Notifier.post(title: "Couldn't regenerate", body: error.localizedDescription, folder: url)
        }
    }

    func recentSessions(limit: Int = 5) -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: settings.outputRoot, includingPropertiesForKeys: [.contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { fm.fileExists(atPath: $0.appending(path: "session.json").path) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(limit).map { $0 }
    }

    // MARK: - Private

    private func startSession() async {
        guard Permission.missing.isEmpty else {
            onboarding.show()
            return
        }
        isStarting = true
        defer { isStarting = false }
        await controller.start(mode: .manual)
        guard controller.isRecording else {
            if case let .failed(message) = controller.state {
                Notifier.post(title: "Couldn't start recording", body: message, folder: nil)
            }
            return
        }
        if let folder = controller.currentFolder { settings.lastSessionPath = folder.url.path }
        pill.show(model: self)
        NSSound(named: "Pop")?.play()
    }

    private func stopSession() async {
        await controller.stop()
        pill.hide()
        partialTranscript = ""
        if case let .done(result) = controller.state, let folder = controller.lastFolder {
            handOff(result, folder: folder)
        }
    }

    private func handOff(_ result: ReportResult, folder: SessionFolder) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.prompt, forType: .string)
        settings.lastSessionPath = folder.url.path
        let body = result.usedAI
            ? "\(result.itemCount) item\(result.itemCount == 1 ? "" : "s") copied. Paste into Claude Code."
            : "Saved without an AI write-up (\(result.error ?? "unknown error")). Prompt copied."
        Notifier.post(title: "Feedback ready", body: body, folder: folder.url)
    }

    private static func makeReportBuilder(_ settings: AppSettings) -> any ReportBuilding {
        ReportBuilder(llm: settings.apiKey().map { ClaudeHTTPClient(apiKey: $0) }, model: settings.reportModel)
    }
}
