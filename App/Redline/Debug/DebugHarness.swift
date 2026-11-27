#if DEBUG
import AppKit
import RedlineCore

@MainActor
private final class EventLog {
    var events: [TimelineEvent] = []
}

/// Runs services for a few seconds outside a real session and shows what they produced.
@MainActor
enum DebugHarness {
    static func run(_ services: [any SessionService], seconds: Double, title: String, mode: SessionMode = .manual,
                    extra: (@MainActor (SessionContext) async -> Void)? = nil) async {
        let root = FileManager.default.temporaryDirectory.appending(path: "redline-debug")
        guard let folder = try? SessionFolder.create(root: root, slug: "debug", date: Date()) else { return }
        let log = EventLog()
        let context = SessionContext(folder: folder, clock: SessionClock(startedAt: Date()), mode: mode,
                                     emit: { log.events.append($0) })
        do {
            for s in services { try await s.start(context: context) }
        } catch {
            alert(title, "Start failed: \(error)")
            return
        }
        await extra?(context)
        try? await Task.sleep(for: .seconds(seconds))
        for s in services.reversed() { await s.stop() }

        let lines = log.events.sorted { $0.time < $1.time }.suffix(15).map { e -> String in
            switch e {
            case let .sentence(_, text, start, _): "[\(MarkdownRenderer.timestamp(start))] said: \(text)"
            case let .click(p, d, t): "[\(MarkdownRenderer.timestamp(t))] click \(Int(p.x)),\(Int(p.y)) display \(d)"
            case let .urlChanged(url, _, t): "[\(MarkdownRenderer.timestamp(t))] url \(url)"
            case let .userMark(a): "[\(MarkdownRenderer.timestamp(a.createdAt))] pen mark"
            default: "[\(MarkdownRenderer.timestamp(e.time))] \(e)"
            }
        }
        alert(title, "\(log.events.count) events\n\n" + lines.joined(separator: "\n") + "\n\nFolder: \(folder.url.path)")
        NSWorkspace.shared.open(folder.rawURL)
    }

    static func alert(_ title: String, _ message: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
#endif
