import AppKit
import ImageIO
import Observation
import RedlineCore

/// One sentence the user said, with the screenshot it goes with. Shown as a row in the island.
@MainActor @Observable
final class FeedEntry: Identifiable {
    let id: UUID
    let text: String
    let end: Double
    /// Screenshot for the row: the live frame with the AI's marks drawn on, else the sentence keyframe.
    var image: NSImage?
    var captions: [String] = []
    /// Waiting for the live AI to mark this sentence.
    var pending: Bool
    /// Included in the copy.
    var included = true
    @ObservationIgnored var hasLiveImage = false

    init(id: UUID, text: String, end: Double, pending: Bool) {
        self.id = id
        self.text = text
        self.end = end
        self.pending = pending
    }
}

/// Builds the island's running list of sentences and screenshots, and holds it for review after stop.
@MainActor @Observable
final class SessionFeed: SessionService, TimelineObserving {
    private(set) var entries: [FeedEntry] = []
    /// True while any sentence is still waiting for its live marks.
    var isWaiting: Bool { entries.contains { $0.pending } }
    var includedIDs: [UUID] { entries.filter(\.included).map(\.id) }

    /// Set before a session starts: whether a live annotator will answer each sentence.
    @ObservationIgnored var expectsLiveResults = false
    @ObservationIgnored private var recording = false
    @ObservationIgnored private var folder: SessionFolder?
    /// Keyframe files (in raw/) in the order they were taken, with their times.
    @ObservationIgnored private var keyframes: [(file: String, t: Double)] = []
    @ObservationIgnored private var waitingForKeyframe: [UUID] = []

    static let thumbnailWidth = 480

    func start(context: SessionContext) async throws {
        entries = []
        keyframes = []
        waitingForKeyframe = []
        folder = context.folder
        recording = true
    }

    func stop() async {
        recording = false
        for e in entries where e.pending { e.pending = false }   // the live annotator stops too
    }

    func observe(_ event: TimelineEvent) {
        switch event {
        case let .sentence(id, text, _, end):
            let live = recording && expectsLiveResults
            entries.append(FeedEntry(id: id, text: text, end: end, pending: live))
            waitingForKeyframe.append(id)
        case let .keyframe(ref, reason):
            keyframes.append((ref.file, ref.t))
            if reason == .sentence, !waitingForKeyframe.isEmpty {
                let id = waitingForKeyframe.removeFirst()
                if let entry = entry(id), entry.image == nil, let folder { loadKeyframe(ref.file, in: folder, into: entry) }
            }
        default:
            break
        }
    }

    /// From LiveAnnotator.onResult: the frame the model saw, with its marks drawn on.
    func liveResult(sentenceID: UUID, frame: LiveFrame?, marks: [Annotation]) {
        guard let entry = entry(sentenceID) else { return }
        entry.pending = false
        entry.captions = marks.compactMap(\.caption)
        guard let frame else { return }
        entry.hasLiveImage = true
        let width = Self.thumbnailWidth
        Task {
            let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithData(frame.jpeg as CFData, nil),
                      let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                let marked = AnnotationCompositor.compose(image: raw, display: frame.display, annotations: marks) ?? raw
                return ImageFiles.downscaled(marked, maxWidth: width)
            }.value
            if let image { entry.image = NSImage(cgImage: image, size: .zero) }
        }
    }

    /// After the controller stopped (and renamed the folder): gives every sentence without a screenshot
    /// the keyframe nearest its end.
    func finish(folder: SessionFolder) {
        self.folder = folder
        waitingForKeyframe = []
        for e in entries {
            e.pending = false
            guard e.image == nil,
                  let nearest = keyframes.min(by: { abs($0.t - e.end) < abs($1.t - e.end) }) else { continue }
            loadKeyframe(nearest.file, in: folder, into: e)
        }
    }

    func setAll(included: Bool) {
        for e in entries { e.included = included }
    }

    // MARK: - Private

    private func entry(_ id: UUID) -> FeedEntry? { entries.last { $0.id == id } }

    private func loadKeyframe(_ file: String, in folder: SessionFolder, into entry: FeedEntry) {
        let url = folder.rawURL.appending(path: file)
        let width = Self.thumbnailWidth
        Task {
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                ImageFiles.load(url).map { ImageFiles.downscaled($0, maxWidth: width) }
            }.value
            // The live frame (with marks) wins if it arrived meanwhile.
            if let image, !entry.hasLiveImage { entry.image = NSImage(cgImage: image, size: .zero) }
        }
    }
}
