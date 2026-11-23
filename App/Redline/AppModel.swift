import AppKit
import KeyboardShortcuts
import Observation
import RedlineCore

@MainActor @Observable
final class AppModel {
    let settings = AppSettings()
    private(set) var partialTranscript = ""
    private(set) var isStarting = false
    /// Live annotation health, for the island's status dot. LiveAnnotator.onStatus feeds this.
    private(set) var liveStatus: LiveStatus = .idle
    @ObservationIgnored private var isRegenerating = false
    @ObservationIgnored private(set) var controller: SessionController!

    @ObservationIgnored private let capture = CaptureService()
    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private let context = ContextService()
    @ObservationIgnored private let speech = SpeechService()
    @ObservationIgnored private var live: LiveAnnotator!
    @ObservationIgnored private let pill = RecordingPillController()
    @ObservationIgnored private let onboarding = OnboardingWindowController()
    let paste = PasteSequencer()

    var isRecording: Bool { controller.isRecording }
    var isFinalizing: Bool { controller.state == .finalizing }
    var lastSessionFolder: URL? { settings.lastSessionPath.map { URL(fileURLWithPath: $0) } }

    init() {
        let settings = self.settings
        live = LiveAnnotator(llm: nil, model: settings.liveModel, frame: { [capture] t in await capture.liveFrame(near: t) })
        controller = SessionController(
            capture: capture,
            services: [overlay, context, speech, live],   // stop order is reversed: live, then speech flushes
            outputRoot: { settings.outputRoot },
            reportBuilder: { Self.makeReportBuilder(settings) })
        context.onPen = { [overlay] in overlay.setPen($0) }
        speech.onPartial = { [weak self] in self?.partialTranscript = $0 }
        live.onMarks = { [overlay] marks in for m in marks { overlay.display(m, lifetime: 6) } }
        live.onStatus = { [weak self] in self?.setLiveStatus($0) }
        paste.onFinished = { [pill] in pill.hide(after: .seconds(2)) }
    }

    func launch() {
        Notifier.setUp()
        SystemAudio.restoreOutput()   // undo a mute left behind if Redline quit mid-session
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SystemAudio.restoreOutput() }
        }
        Hotkeys.migrateOldDefaults()
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
        SystemAudio.restoreOutput()
        liveStatus = .idle
        if wasActive { pill.hide() }
        partialTranscript = ""
    }

    func markMoment() {
        guard isRecording else { return }
        controller.markMoment()
        NSSound(named: "Tink")?.play()
    }

    func showOnboarding() { onboarding.show() }

    func setLiveStatus(_ status: LiveStatus) { liveStatus = status }

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
        let mode = settings.sessionMode
        if mode == .live && settings.apiKey() == nil {
            Notifier.post(title: "Can't start Live mode",
                          body: "Live mode needs a Claude API key. Add one in Settings, or switch to Manual.", folder: nil)
            return
        }
        isStarting = true
        defer { isStarting = false }
        liveStatus = .idle
        live.configure(llm: mode == .manual ? nil : settings.apiKey().map { ClaudeHTTPClient(apiKey: $0) }, model: settings.liveModel)
        await controller.start(mode: mode)
        guard controller.isRecording else {
            if case let .failed(message) = controller.state {
                Notifier.post(title: "Couldn't start recording", body: message, folder: nil)
            }
            return
        }
        if let folder = controller.currentFolder { settings.lastSessionPath = folder.url.path }
        pill.show(model: self)
        NSSound(named: "Pop")?.play()
        // Silence other apps while recording; wait for the start sound to finish first.
        try? await Task.sleep(for: .milliseconds(300))
        if controller.isRecording { SystemAudio.muteOutput() }
    }

    private func stopSession() async {
        await controller.stop()
        SystemAudio.restoreOutput()
        liveStatus = .idle
        partialTranscript = ""
        guard case let .done(result) = controller.state, let folder = controller.lastFolder else {
            pill.hide()
            return
        }
        handOff(result, folder: folder)
        // The island stays up as the "Feedback ready" confirmation; banners are easy to miss. In paste
        // mode it holds the Copy Screenshots button, so it stays until closed.
        NSSound(named: "Glass")?.play()
        if !settings.pasteForOtherComputer { pill.hide(after: .seconds(10)) }
    }

    /// Starts the "paste twice" hand-off for a Claude chat on another computer: the write-up text is
    /// on the clipboard now, and the screenshots replace it after the first ⌘V.
    @discardableResult
    func copyWriteup(folder: URL) -> Bool {
        guard let markdown = try? String(contentsOf: SessionFolder(url: folder).feedbackURL, encoding: .utf8) else { return false }
        paste.start(text: HandoffPrompt.inline(markdown: markdown), images: Self.imageItems(folder: folder, markdown: markdown))
        return true
    }

    /// Puts only the screenshots on the clipboard.
    func copyScreenshots(folder: URL) {
        paste.cancel()
        let markdown = (try? String(contentsOf: SessionFolder(url: folder).feedbackURL, encoding: .utf8)) ?? ""
        let items = Self.imageItems(folder: folder, markdown: markdown)
        guard !items.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
    }

    /// One clipboard item per screenshot the write-up links, in order: file URL plus PNG data.
    private static func imageItems(folder: URL, markdown: String) -> [NSPasteboardItem] {
        HandoffPrompt.imageFiles(in: markdown).compactMap { name in
            let url = folder.appending(path: name)
            guard let data = try? Data(contentsOf: url) else { return nil }
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setData(data, forType: .png)
            return item
        }
    }

    private func handOff(_ result: ReportResult, folder: SessionFolder) {
        paste.cancel()
        if !(settings.pasteForOtherComputer && copyWriteup(folder: folder.url)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.prompt, forType: .string)
        }
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
