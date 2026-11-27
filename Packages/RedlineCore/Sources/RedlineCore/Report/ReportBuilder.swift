import CoreGraphics
import Foundation
import os

public struct ReportResult: Equatable, Sendable {
    public var itemCount: Int
    public var usedAI: Bool
    public var prompt: String
    public var error: String?
    public var tokens: TokenUsage
    /// The model that wrote the report, when the AI ran.
    public var model: String?
    /// Tokens spent by Live mode during the session (separate from the report call), and its model.
    public var liveTokens: TokenUsage = TokenUsage()
    public var liveModel: String?

    /// Estimated API cost in US dollars, when the model's price is known.
    public var costUSD: Double? { model.flatMap { Pricing.cost(model: $0, tokens: tokens) } }

    public init(itemCount: Int, usedAI: Bool, prompt: String, error: String?, tokens: TokenUsage, model: String? = nil) {
        self.model = model
        self.itemCount = itemCount
        self.usedAI = usedAI
        self.prompt = prompt
        self.error = error
        self.tokens = tokens
    }
}

public protocol ReportBuilding: Sendable {
    func build(document: SessionDocument, folder: SessionFolder) async -> ReportResult
}

private let reportLog = Logger(subsystem: "com.dmschellaz.redline", category: "report")

public struct ReportBuilder: ReportBuilding {
    public static let maxImages = 20
    public static let apiImageWidth = 1280
    public static let outputImageWidth = 2560

    private let llm: LLMClient?
    private let model: String
    private let timeZone: TimeZone

    public init(llm: LLMClient?, model: String, timeZone: TimeZone = .current) {
        self.llm = llm
        self.model = model
        self.timeZone = timeZone
    }

    public func build(document: SessionDocument, folder: SessionFolder) async -> ReportResult {
        let moments = MomentSegmenter.segment(document.events)
        let composed = composeImages(moments: moments, document: document, folder: folder)
        let transcript = TranscriptBuilder.lines(document.events)
        let startURL = document.events.lazy.compactMap { e -> String? in
            guard case let .urlChanged(url, _, _) = e else { return nil }
            return url
        }.first

        var items = FallbackReport.items(from: moments)
        var usedAI = false
        var errorText: String? = llm == nil ? "No API key set" : nil
        var tokens = TokenUsage()
        var servedBy: String?

        if llm != nil, moments.isEmpty {
            errorText = "Nothing was said or marked in this session."
        }

        if let llm, !moments.isEmpty {
            let ids = composed.keys.sorted().prefix(Self.maxImages)
            var images: [Int: Data] = [:]
            for id in ids {
                if let jpeg = ImageFiles.jpegData(composed[id]!, maxWidth: Self.apiImageWidth) { images[id] = jpeg }
            }
            let input = ReportInput(moments: moments, images: images, transcript: transcript, startURL: startURL)
            do {
                let response = try await llm.send(ReportRequest.make(model: model, input: input))
                guard let text = response.firstText() else { throw ClaudeError.noText }
                items = try ReportRequest.parse(text, validMomentIDs: Set(moments.map(\.id)))
                usedAI = true
                tokens = TokenUsage(input: response.usage?.input_tokens ?? 0, output: response.usage?.output_tokens ?? 0)
                servedBy = response.model ?? model
            } catch {
                Self.log(error)
                errorText = ReportErrorText.describe(error)
            }
        }

        var imageFiles: [Int: String] = [:]
        for (i, item) in items.enumerated() {
            guard let mid = item.momentIDs.first(where: { composed[$0] != nil }), let image = composed[mid] else { continue }
            let name = String(format: "%02d", i + 1) + "-" + Slug.make(item.title) + ".png"
            do {
                try ImageFiles.writePNG(ImageFiles.downscaled(image, maxWidth: Self.outputImageWidth), to: folder.url.appending(path: name))
                imageFiles[i] = name
            } catch {
                continue
            }
        }

        // A crashed session has no endedAt; fall back to the latest event time.
        let duration: Double
        if let endedAt = document.metadata.endedAt {
            duration = endedAt.timeIntervalSince(document.metadata.startedAt)
        } else {
            duration = document.events.map(\.time).filter(\.isFinite).max() ?? 0
        }
        let context = ReportContext(appName: SessionFolder.slug(fromURL: startURL), startURL: startURL,
                                    startedAt: document.metadata.startedAt, duration: duration, mode: document.metadata.mode,
                                    transcript: transcript, imageFiles: imageFiles, timeZone: timeZone)
        let markdown = MarkdownRenderer.render(items: items, context: context)
        do {
            try markdown.write(to: folder.feedbackURL, atomically: true, encoding: .utf8)
        } catch {
            errorText = "Couldn't write feedback.md: \(error.localizedDescription)"
        }

        return ReportResult(itemCount: items.count, usedAI: usedAI, prompt: HandoffPrompt.make(folder: folder),
                            error: errorText, tokens: tokens, model: servedBy)
    }

    private static func log(_ error: Error) {
        if let e = error as? ClaudeError {
            switch e {
            case let .http(status, body):
                reportLog.error("Claude API HTTP \(status, privacy: .public): \(body, privacy: .public)")
            case let .invalidJSON(text):
                reportLog.error("Claude returned invalid JSON: \(String(text.prefix(500)), privacy: .public)")
            default:
                reportLog.error("Claude error: \(String(describing: e), privacy: .public)")
            }
        } else {
            reportLog.error("Report error: \(String(describing: error), privacy: .public)")
        }
    }

    private func composeImages(moments: [Moment], document: SessionDocument, folder: SessionFolder) -> [Int: CGImage] {
        var out: [Int: CGImage] = [:]
        for m in moments {
            guard let kf = m.keyframe,
                  let raw = ImageFiles.load(folder.rawURL.appending(path: kf.file)),
                  let display = document.metadata.displays.first(where: { $0.id == kf.displayID }) else { continue }
            out[m.id] = AnnotationCompositor.compose(image: raw, display: display, annotations: m.userMarks + m.aiMarks) ?? raw
        }
        return out
    }
}
