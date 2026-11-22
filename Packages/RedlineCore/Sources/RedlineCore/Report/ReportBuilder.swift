import CoreGraphics
import Foundation

public struct ReportResult: Equatable, Sendable {
    public var itemCount: Int
    public var usedAI: Bool
    public var prompt: String
    public var error: String?
    public var tokens: TokenUsage

    public init(itemCount: Int, usedAI: Bool, prompt: String, error: String?, tokens: TokenUsage) {
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
            } catch {
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

        let duration = (document.metadata.endedAt ?? document.metadata.startedAt).timeIntervalSince(document.metadata.startedAt)
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
                            error: errorText, tokens: tokens)
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
