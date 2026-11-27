import CoreGraphics
import Foundation

/// Builds the Live-mode "annotate" request and turns its answer into on-screen AI marks.
/// In Chatty mode the same request also asks for a short spoken line and an optional clarifying question.
public enum AnnotateRequest {
    /// At most this many marks are kept from one answer.
    public static let maxMarks = 3
    /// Chatty limits (spec §10): a spoken line is at most 12 words; a question has 2–3 options of at most 4 words.
    public static let maxSayWords = 12
    public static let maxOptionWords = 4
    public static let minOptions = 2
    public static let maxOptions = 3
    /// Boxes thinner than this (image pixels) are widened to it around their centre, so a point or a
    /// one-line answer still makes a visible mark.
    static let minBox: Double = 16
    /// How far an arrow's tail starts from its tip, in image pixels.
    static let arrowLength = CGSize(width: 70, height: 40)

    public static let systemPrompt = """
    You watch a reviewer talk through an app on their screen. After each sentence they say, you get a \
    screenshot of their display and you mark what the reviewer is referring to, so they can see you understood.

    - Find the thing on screen the reviewer means and give its bounding box: x, y is its top-left corner and \
    w, h its size, in the screenshot's pixel space (origin top-left, x right, y down). Fit the box tightly \
    around the element (the card, button, column or text), and always give real values: w and h are never 0.
    - The mouse pointer is visible in the screenshot. Reviewers usually rest it on what they are talking about, \
    so use it with their words. Their recent clicks are given in the same pixel space.
    - shape says how to draw the mark around that box: "circle" for a small thing or a single value, "rect" for \
    a card, panel or area, "highlight" for a line of text, "arrow" to point at something small or easily missed.
    - Prefer one mark; use two or three only if they clearly point at several things.
    - caption: the change the reviewer is asking for, as a short instruction of at most 8 words, written like a \
    note on a printout: "Rename to NSR revenue", "Make this purple", "Show in thousands". Don't describe what is \
    there now. If they only point at something without asking for a change, name it briefly.
    - If the sentence doesn't refer to anything on screen (thinking aloud, "ok, next"), return no marks.
    """

    /// Appended to `systemPrompt` in Chatty mode.
    public static let chattyPrompt = """
    Chatty mode is on: as well as marking, you can talk to the reviewer. What you put in say and question is read aloud.
    - say: one short line of at most 12 words, or "" to stay silent. Stay silent most of the time and just mark. \
    Speak only when your mark might be wrong ("I marked the left card. Is that it?") or when the reviewer has \
    moved on to a new topic or page ("Now looking at billing."). Never repeat their words or describe your mark.
    - question: ask only when two or more things on screen fit what they said, or when the change they want is \
    unclear. text is the question, at most 12 words, and must make sense heard on its own. options are 2 or 3 \
    short answers of at most 4 words each; they are shown as buttons. When you ask, still mark your best guess \
    and leave say "". When you don't need to ask, give text "" and options [].
    - If you just asked a question, this sentence is the reviewer's answer: mark what they picked and don't ask again.
    """

    public static let schema: JSONValue = makeSchema(chatty: false)
    public static let chattySchema: JSONValue = makeSchema(chatty: true)

    static func makeSchema(chatty: Bool) -> JSONValue {
        func num() -> JSONValue { .object(["type": .string("number")]) }
        func str() -> JSONValue { .object(["type": .string("string")]) }
        let keys = ["shape", "x", "y", "w", "h", "caption"]
        let mark: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "shape": .object([
                    "type": .string("string"),
                    "enum": .array(["circle", "rect", "arrow", "highlight"].map(JSONValue.string)),
                ]),
                "x": num(), "y": num(), "w": num(), "h": num(),
                "caption": str(),
            ]),
            "required": .array(keys.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
        var properties: [String: JSONValue] = ["marks": .object(["type": .string("array"), "items": mark])]
        var required: [JSONValue] = [.string("marks")]
        if chatty {
            properties["say"] = str()
            properties["question"] = .object([
                "type": .string("object"),
                "properties": .object([
                    "text": str(),
                    "options": .object(["type": .string("array"), "items": str()]),
                ]),
                "required": .array([.string("text"), .string("options")]),
                "additionalProperties": .bool(false),
            ])
            required += [.string("say"), .string("question")]
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required),
            "additionalProperties": .bool(false),
        ])
    }

    /// - Parameters:
    ///   - sentence: the sentence just finished.
    ///   - recentSentences: earlier sentences for context, oldest first (the current one excluded).
    ///   - clicks: clicks since the previous sentence, in global points, on `frame.display`.
    ///   - chatty: adds `chattyPrompt` and the `say`/`question` fields.
    ///   - answering: the question this sentence answers (Chatty voice answer), if any.
    public static func make(model: String, frame: LiveFrame, sentence: String, recentSentences: [String],
                            clicks: [CGPoint], url: String?, chatty: Bool = false, answering: String? = nil) -> MessagesRequest {
        var lines: [String] = []
        lines.append("Page: \(url ?? "unknown")")
        lines.append("Screenshot size: \(Int(frame.pixelSize.width.rounded()))x\(Int(frame.pixelSize.height.rounded())) px")
        if !recentSentences.isEmpty {
            lines.append("Earlier sentences:\n" + recentSentences.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !clicks.isEmpty {
            let pts = clicks.map { p -> String in
                let ip = CoordinateMapper.imagePoint(fromGlobal: p, imageSize: frame.pixelSize, on: frame.display)
                return "(\(Int(ip.x.rounded())), \(Int(ip.y.rounded())))"
            }
            lines.append("Clicks (image px): " + pts.joined(separator: ", "))
        }
        if let answering {
            lines.append("You asked: \(answering)\nThis sentence is the reviewer's answer.")
        }
        lines.append("Reviewer just said: \(sentence)")

        return MessagesRequest(
            model: model,
            max_tokens: 2000,
            system: chatty ? systemPrompt + "\n\n" + chattyPrompt : systemPrompt,
            messages: [.init(role: "user", content: [.jpeg(frame.jpeg), .text(lines.joined(separator: "\n"))])],
            output_config: .init(effort: "low", format: .init(schema: chatty ? chattySchema : schema)),
            thinking: thinking(for: model),
            fallbacks: model.hasPrefix("claude-sonnet") ? "default" : nil)
    }

    /// Thinking off: a live mark is a quick look, and reasoning made answers several seconds slower.
    /// Haiku turns it off with "disabled"; Sonnet 5.5 rejects that and uses "between_tools" (no tools here).
    static func thinking(for model: String) -> MessagesRequest.Thinking? {
        if model.hasPrefix("claude-haiku") { return .init(type: "disabled") }
        if model.hasPrefix("claude-sonnet-5-5") { return .init(type: "between_tools") }
        return nil
    }

    private struct Mark: Decodable {
        var shape: String
        var x, y, w, h: Double
        var caption: String
    }
    private struct Question: Decodable {
        var text: String
        var options: [String]
    }
    /// `say` and `question` are only present in Chatty answers.
    private struct Envelope: Decodable {
        var marks: [Mark]
        var say: String?
        var question: Question?
    }

    /// Converts the model's answer into AI annotations in global points (see `parseAnswer`).
    public static func parse(_ text: String, frame: LiveFrame, createdAt: Double) throws -> [Annotation] {
        try parseAnswer(text, frame: frame, createdAt: createdAt).marks
    }

    /// Reads a Live or Chatty answer.
    /// - Marks: a box with no position at all is dropped, a too-thin one is widened, everything is clamped to
    ///   the image, and at most `maxMarks` are kept.
    /// - `say` is trimmed to `maxSayWords` words.
    /// - The question is trimmed. Its options are cut to `maxOptionWords` words, de-duplicated ignoring case and
    ///   capped at `maxOptions`. It is dropped if its text is empty or fewer than `minOptions` options remain.
    public static func parseAnswer(_ text: String, frame: LiveFrame, createdAt: Double) throws -> LiveAnswer {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
        } catch {
            throw ClaudeError.invalidJSON(String(text.prefix(200)))
        }
        return LiveAnswer(marks: annotations(envelope.marks, frame: frame, createdAt: createdAt),
                          say: words(envelope.say ?? "", max: maxSayWords),
                          question: envelope.question.flatMap(liveQuestion))
    }

    /// The first `max` words of `s`, with runs of whitespace collapsed; "" when blank.
    static func words(_ s: String, max: Int) -> String {
        s.split(whereSeparator: \.isWhitespace).prefix(max).joined(separator: " ")
    }

    private static func liveQuestion(_ q: Question) -> LiveQuestion? {
        let text = q.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [String] = []
        for option in q.options.map({ words($0, max: maxOptionWords) }) where !option.isEmpty {
            if !options.contains(where: { $0.caseInsensitiveCompare(option) == .orderedSame }) { options.append(option) }
        }
        options = Array(options.prefix(maxOptions))
        guard !text.isEmpty, options.count >= minOptions else { return nil }
        return LiveQuestion(text: text, options: options)
    }

    private static func annotations(_ marks: [Mark], frame: LiveFrame, createdAt: Double) -> [Annotation] {
        let size = frame.pixelSize
        guard size.width > 0, size.height > 0 else { return [] }
        let bounds = CGRect(origin: .zero, size: size)
        let display = frame.display
        func global(_ p: CGPoint) -> CGPoint {
            CoordinateMapper.global(fromImagePoint: p, imageSize: size, on: display)
        }
        func clamp(_ p: CGPoint) -> CGPoint {
            CGPoint(x: min(max(p.x, 0), size.width), y: min(max(p.y, 0), size.height))
        }
        func globalRect(_ r: CGRect) -> CGRect {
            let a = global(CGPoint(x: r.minX, y: r.minY)), b = global(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        /// Image pixels → points (the frame covers the whole display).
        let pointsPerPixel = display.frame.width / size.width

        var out: [Annotation] = []
        for m in marks {
            guard [m.x, m.y, m.w, m.h].allSatisfy(\.isFinite), !(m.x == 0 && m.y == 0 && m.w == 0 && m.h == 0) else { continue }
            var box = CGRect(x: m.x, y: m.y, width: m.w, height: m.h).standardized
            box = box.insetBy(dx: -max(0, minBox - box.width) / 2, dy: -max(0, minBox - box.height) / 2)
            box = box.intersection(bounds)
            guard !box.isNull, box.width >= 1, box.height >= 1 else { continue }

            let shape: AnnotationShape
            switch m.shape {
            case "circle":
                let radius = max(box.width, box.height) / 2 * 1.15 + 4
                shape = .circle(center: global(CGPoint(x: box.midX, y: box.midY)), radius: radius * pointsPerPixel)
            case "rect":
                shape = .rect(globalRect(box.insetBy(dx: -4, dy: -4).intersection(bounds)))
            case "highlight":
                shape = .highlight(globalRect(box))
            case "arrow":
                // Points at the box's left edge from up-left, or from the right when there's no room.
                let fromLeft = box.minX - 4 - arrowLength.width >= 0
                let tip = CGPoint(x: fromLeft ? box.minX - 4 : box.maxX + 4, y: box.midY)
                let tail = CGPoint(x: tip.x + (fromLeft ? -arrowLength.width : arrowLength.width),
                                   y: tip.y - arrowLength.height)
                shape = .arrow(from: global(clamp(tail)), to: global(clamp(tip)))
            default:
                continue
            }
            let caption = m.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(Annotation(shape: shape, caption: caption.isEmpty ? nil : caption, author: .ai,
                                  createdAt: createdAt, displayID: display.id))
            if out.count == maxMarks { break }
        }
        return out
    }
}
