import Foundation

public struct ReportInput: Sendable {
    public var moments: [Moment]
    /// JPEG data keyed by moment id.
    public var images: [Int: Data]
    public var transcript: [TranscriptLine]
    public var startURL: String?

    public init(moments: [Moment], images: [Int: Data], transcript: [TranscriptLine], startURL: String?) {
        self.moments = moments
        self.images = images
        self.transcript = transcript
        self.startURL = startURL
    }
}

public enum ReportRequest {
    public static let systemPrompt = """
    You turn a recorded, spoken review of an app into a list of concrete revision requests. A coding agent \
    (Claude Code) will read your list and edit the app's source code, so each item must stand on its own.

    You receive numbered moments. Each has the reviewer's words, the page URL, and usually a screenshot. \
    Red marks on a screenshot are the reviewer's own: they drew them to point at something. \
    Blue marks with short labels are a live AI's guesses at what the reviewer meant, made while they talked. \
    Use the blue marks as hints, but trust the reviewer's words and red marks over them.

    - Merge moments that are about the same issue. Drop moments with no feedback in them (thinking aloud, \
    "ok, next page").
    - title: at most 8 words naming the change.
    - where: the route plus the UI element, e.g. "/settings/billing, the Current plan card".
    - problem: what is wrong, in the reviewer's terms.
    - wanted: the change they asked for. If they didn't say, give the most likely intent, starting with "Likely: ".
    - quote: the reviewer's most relevant words, verbatim.
    - image_caption: what the marks on the screenshot show, naming the colour, e.g. "red circle marks the card; \
    blue box (live AI) marks the Save button". Use "" if there are none.
    - moment_ids: the moments the item comes from.

    Use only what the reviewer said and what is visible. Don't invent requirements.
    """

    public static let schema: JSONValue = {
        func str() -> JSONValue { .object(["type": .string("string")]) }
        let item: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "title": str(),
                "moment_ids": .object(["type": .string("array"), "items": .object(["type": .string("integer")])]),
                "where": str(),
                "problem": str(),
                "wanted": str(),
                "quote": str(),
                "image_caption": str(),
            ]),
            "required": .array(["title", "moment_ids", "where", "problem", "wanted", "quote", "image_caption"].map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object(["items": .object(["type": .string("array"), "items": item])]),
            "required": .array([.string("items")]),
            "additionalProperties": .bool(false),
        ])
    }()

    public static func make(model: String, input: ReportInput) -> MessagesRequest {
        var blocks: [ContentBlock] = [.text("Review started at: \(input.startURL ?? "unknown page")\n\nMoments follow.")]
        for m in input.moments {
            let header = "Moment \(m.id) [\(MarkdownRenderer.timestamp(m.start))–\(MarkdownRenderer.timestamp(m.end))]"
                + " on \(m.url ?? "unknown page")"
                + (m.userMarks.isEmpty ? "" : " (reviewer drew \(m.userMarks.count) mark(s))")
                + aiMarksNote(m.aiMarks)
            blocks.append(.text("\(header)\nReviewer said: \(m.text.isEmpty ? "(nothing)" : m.text)"))
            if let jpeg = input.images[m.id] { blocks.append(.jpeg(jpeg)) }
        }
        let transcript = input.transcript.map { "[\(MarkdownRenderer.timestamp($0.t))] \($0.text)" }.joined(separator: "\n")
        blocks.append(.text("Full transcript with clicks, navigation and live AI marks:\n\(transcript)\n\nWrite the revision list."))

        return MessagesRequest(
            model: model,
            max_tokens: 16000,
            system: systemPrompt,
            messages: [.init(role: "user", content: blocks)],
            output_config: .init(effort: "medium", format: .init(schema: schema)),
            fallbacks: "default")
    }

    /// ` (live AI marked: "Billing card", "Save button")`, or "" when the AI drew nothing.
    static func aiMarksNote(_ marks: [Annotation]) -> String {
        guard !marks.isEmpty else { return "" }
        let captioned = marks.filter { !($0.caption?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }
        let uncaptioned = marks.count - captioned.count
        var parts = captioned.isEmpty ? [] : [FallbackReport.quotedCaptions(captioned)]
        if uncaptioned > 0 { parts.append("\(uncaptioned) unlabeled mark(s)") }
        return " (live AI marked: \(parts.joined(separator: ", ")))"
    }

    private struct Envelope: Decodable { var items: [FeedbackItem] }

    public static func parse(_ text: String, validMomentIDs: Set<Int>) throws -> [FeedbackItem] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
        } catch {
            throw ClaudeError.invalidJSON(String(text.prefix(200)))
        }
        return envelope.items.compactMap { item in
            var item = item
            item.momentIDs = item.momentIDs.filter(validMomentIDs.contains)
            return item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : item
        }
    }
}
