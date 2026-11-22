import Foundation

public struct TranscriptLine: Equatable, Sendable {
    public var t: Double
    public var text: String
    public init(t: Double, text: String) {
        self.t = t
        self.text = text
    }
}

public enum TranscriptBuilder {
    public static func lines(_ events: [TimelineEvent]) -> [TranscriptLine] {
        events.sorted { $0.time < $1.time }.compactMap { e in
            switch e {
            case let .sentence(_, text, start, _): return TranscriptLine(t: start, text: text)
            case let .click(_, _, t): return TranscriptLine(t: t, text: "(click)")
            case let .urlChanged(url, _, t): return TranscriptLine(t: t, text: "(opened \(FallbackReport.pathOf(url)))")
            case let .momentMarked(t): return TranscriptLine(t: t, text: "(marked moment)")
            case let .userMark(a): return TranscriptLine(t: a.createdAt, text: "(drew on screen)")
            case .keyframe, .aiAnnotation: return nil
            }
        }
    }
}

public struct ReportContext: Sendable {
    public var appName: String
    public var startURL: String?
    public var startedAt: Date
    public var duration: Double
    public var mode: SessionMode
    public var transcript: [TranscriptLine]
    /// Keyed by 0-based item index.
    public var imageFiles: [Int: String]
    public var timeZone: TimeZone

    public init(appName: String, startURL: String?, startedAt: Date, duration: Double, mode: SessionMode,
                transcript: [TranscriptLine], imageFiles: [Int: String], timeZone: TimeZone = .current) {
        self.appName = appName
        self.startURL = startURL
        self.startedAt = startedAt
        self.duration = duration
        self.mode = mode
        self.transcript = transcript
        self.imageFiles = imageFiles
        self.timeZone = timeZone
    }
}

public enum MarkdownRenderer {
    public static func render(items: [FeedbackItem], context: ReportContext) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = context.timeZone
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let secs = context.duration.isFinite ? max(0, Int(context.duration.rounded())) : 0

        var out = "# Feedback: \(context.appName) — \(df.string(from: context.startedAt))\n"
        out += "Reviewed at: \(context.startURL ?? "unknown page") · \(secs / 60)m \(secs % 60)s · mode: \(context.mode.title)\n"

        if items.isEmpty {
            out += "\n_No feedback items were found in this session._\n"
        }
        for (i, item) in items.enumerated() {
            out += "\n## \(i + 1). \(item.title)\n"
            func line(_ label: String, _ value: String) {
                if !value.isEmpty { out += "- **\(label):** \(value)\n" }
            }
            line("Where", item.location)
            line("Problem", item.problem)
            line("Wanted", item.wanted)
            line("You said", item.quote.isEmpty ? "" : "\"\(item.quote)\"")
            if let file = context.imageFiles[i] {
                out += "- **Screenshot:** ![](\(file))" + (item.imageCaption.isEmpty ? "" : " — \(item.imageCaption)") + "\n"
            }
        }

        out += "\n---\n## Full transcript\n"
        for l in context.transcript {
            out += "[\(timestamp(l.t))] \(l.text)\n"
        }
        return out
    }

    public static func timestamp(_ t: Double) -> String {
        let s = t.isFinite ? max(0, Int(t)) : 0
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

public enum HandoffPrompt {
    public static func make(folder: SessionFolder) -> String {
        var path = (folder.feedbackURL.path as NSString).abbreviatingWithTildeInPath
        if path.contains(" ") { path = "\"\(path)\"" }
        return "Read \(path) and the screenshots it links, then make each revision in this project. Ask me if an item is ambiguous."
    }
}
