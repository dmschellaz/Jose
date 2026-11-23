import CoreGraphics
import Foundation

/// Builds the Live-mode "annotate" request and turns its answer into on-screen AI marks.
public enum AnnotateRequest {
    /// At most this many marks are kept from one answer.
    public static let maxMarks = 3
    /// Marks smaller than this (in image pixels) are dropped as degenerate.
    static let minExtent: Double = 2

    public static let systemPrompt = """
    You watch a reviewer talk through an app on their screen. After each sentence they say, you get a \
    screenshot of their display and you mark what the reviewer is referring to, so they can see you understood.

    - Mark what the user is referring to. Prefer one shape; use two or three only if they clearly point at \
    several things.
    - Coordinates are in the screenshot's pixel space: origin top-left, x right, y down.
    - shape "circle": x, y is the center and w is the diameter.
    - shape "rect" or "highlight": x, y is the top-left corner, w and h the size. Use highlight for text.
    - shape "arrow": from x, y to x2, y2, pointing at the thing.
    - Set every unused number to 0.
    - caption: at most 8 words naming what you marked.
    - The reviewer's recent clicks are given in the same pixel space; they often point at the subject.
    - If the sentence doesn't refer to anything on screen (thinking aloud, "ok, next"), return no marks.
    """

    public static let schema: JSONValue = {
        func num() -> JSONValue { .object(["type": .string("number")]) }
        let keys = ["shape", "x", "y", "w", "h", "x2", "y2", "caption"]
        let mark: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "shape": .object([
                    "type": .string("string"),
                    "enum": .array(["circle", "rect", "arrow", "highlight"].map(JSONValue.string)),
                ]),
                "x": num(), "y": num(), "w": num(), "h": num(), "x2": num(), "y2": num(),
                "caption": .object(["type": .string("string")]),
            ]),
            "required": .array(keys.map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
        return .object([
            "type": .string("object"),
            "properties": .object(["marks": .object(["type": .string("array"), "items": mark])]),
            "required": .array([.string("marks")]),
            "additionalProperties": .bool(false),
        ])
    }()

    /// - Parameters:
    ///   - sentence: the sentence just finished.
    ///   - recentSentences: earlier sentences for context, oldest first (the current one excluded).
    ///   - clicks: clicks since the previous sentence, in global points, on `frame.display`.
    public static func make(model: String, frame: LiveFrame, sentence: String, recentSentences: [String],
                            clicks: [CGPoint], url: String?) -> MessagesRequest {
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
        lines.append("Reviewer just said: \(sentence)")

        return MessagesRequest(
            model: model,
            max_tokens: 2000,
            system: systemPrompt,
            messages: [.init(role: "user", content: [.jpeg(frame.jpeg), .text(lines.joined(separator: "\n"))])],
            output_config: .init(effort: "low", format: .init(schema: schema)),
            fallbacks: model.hasPrefix("claude-sonnet") ? "default" : nil)
    }

    private struct Mark: Decodable {
        var shape: String
        var x, y, w, h, x2, y2: Double
        var caption: String
    }
    private struct Envelope: Decodable { var marks: [Mark] }

    /// Converts the model's answer (image pixels) into AI annotations in global points.
    /// Marks are clamped to the image; degenerate or unknown ones are dropped; at most `maxMarks` are kept.
    public static func parse(_ text: String, frame: LiveFrame, createdAt: Double) throws -> [Annotation] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: Data(text.utf8))
        } catch {
            throw ClaudeError.invalidJSON(String(text.prefix(200)))
        }
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
        func clampedRect(_ m: Mark) -> CGRect? {
            let r = CGRect(x: m.x, y: m.y, width: m.w, height: m.h).standardized.intersection(bounds)
            guard !r.isNull, r.width >= minExtent, r.height >= minExtent else { return nil }
            let a = global(CGPoint(x: r.minX, y: r.minY)), b = global(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        }
        /// Image pixels → points (the frame covers the whole display).
        let pointsPerPixel = display.frame.width / size.width

        var out: [Annotation] = []
        for m in envelope.marks {
            guard [m.x, m.y, m.w, m.h, m.x2, m.y2].allSatisfy(\.isFinite) else { continue }
            let shape: AnnotationShape
            switch m.shape {
            case "circle":
                let c = clamp(CGPoint(x: m.x, y: m.y))
                let radius = abs(m.w) / 2
                guard radius * 2 >= minExtent else { continue }
                shape = .circle(center: global(c), radius: radius * pointsPerPixel)
            case "rect":
                guard let r = clampedRect(m) else { continue }
                shape = .rect(r)
            case "highlight":
                guard let r = clampedRect(m) else { continue }
                shape = .highlight(r)
            case "arrow":
                let a = clamp(CGPoint(x: m.x, y: m.y)), b = clamp(CGPoint(x: m.x2, y: m.y2))
                guard hypot(b.x - a.x, b.y - a.y) >= minExtent else { continue }
                shape = .arrow(from: global(a), to: global(b))
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
