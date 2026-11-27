import AppKit
import Observation
import RedlineCore
import SwiftUI

/// The black "island" that drops out of the top-centre of the screen (around the notch, if there is
/// one) while recording, writing the report, and when feedback is ready.
@MainActor
final class RecordingPillController {
    private var panel: NSPanel?
    private let presence = IslandPresence()
    private var hideTask: Task<Void, Never>?

    func show(model: AppModel) {
        hideTask?.cancel()
        hideTask = nil
        if panel == nil, let screen = NSScreen.main {
            let topInset = screen.safeAreaInsets.top   // notch height; 0 on displays without one
            // Resized to the island's height as rows are added (see resize), anchored to the top edge.
            let size = NSSize(width: Island.width, height: topInset + Island.contentHeight)
            let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
            let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar   // above the menu bar, so the island sits flush with the top edge
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let hosting = NSHostingView(rootView: IslandView(model: model, presence: presence, topInset: topInset,
                                                             close: { [weak self] in self?.hide() },
                                                             resize: { [weak self] in self?.resize(height: $0) }))
            hosting.safeAreaRegions = []
            p.contentView = hosting
            p.orderFrontRegardless()
            panel = p
        }
        presence.shown = true
    }

    private func resize(height: CGFloat) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let frame = NSRect(x: screen.frame.midX - Island.width / 2, y: screen.frame.maxY - height,
                           width: Island.width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// Hides now, or after `delay`. Showing again (e.g. a new session) cancels a pending hide.
    func hide(after delay: Duration? = nil) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            self?.dismiss()
        }
    }

    private func dismiss() {
        guard panel != nil else { return }
        presence.shown = false
        // Let the shrink animation play, then remove the panel unless it was shown again meanwhile.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !self.presence.shown else { return }
            self.panel?.orderOut(nil)
            self.panel = nil
        }
    }
}

@MainActor @Observable
private final class IslandPresence {
    var shown = false
}

private enum Island {
    static let width: CGFloat = 640
    static let contentHeight: CGFloat = 76
    /// Extra room for the "Live: …" cost line on the done state.
    static let extraLineHeight: CGFloat = 15
    static let rowHeight: CGFloat = 58
    static let rowsWhileRecording = 3
    static let rowsInReview = 5
    static let footerHeight: CGFloat = 44
    /// Chatty's question bar: the question on one line, its answer buttons under it.
    static let questionHeight: CGFloat = 58
    static let flare: CGFloat = 10      // concave "ears" where the island meets the top edge
    static let cornerRadius: CGFloat = 22
}

/// Flat top flush with the screen edge, small concave flares at the top corners, and large rounded
/// bottom corners, so it reads as part of the display rather than a floating window.
private struct IslandShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height, f = flare
        let r = min(radius, (w - 2 * f) / 2, h - f)
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addQuadCurve(to: CGPoint(x: f, y: f), control: CGPoint(x: f, y: 0))
        p.addLine(to: CGPoint(x: f, y: h - r))
        p.addQuadCurve(to: CGPoint(x: f + r, y: h), control: CGPoint(x: f, y: h))
        p.addLine(to: CGPoint(x: w - f - r, y: h))
        p.addQuadCurve(to: CGPoint(x: w - f, y: h - r), control: CGPoint(x: w - f, y: h))
        p.addLine(to: CGPoint(x: w - f, y: f))
        p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - f, y: 0))
        p.closeSubpath()
        return p
    }
}

private struct IslandView: View {
    let model: AppModel
    let presence: IslandPresence
    let topInset: CGFloat
    let close: () -> Void
    let resize: (CGFloat) -> Void

    private var visibleRows: Int {
        let n = model.feed.entries.count
        switch model.controller.state {
        case .recording: return min(n, Island.rowsWhileRecording)
        case .reviewing: return min(n, Island.rowsInReview)
        default: return 0
        }
    }

    /// Chatty's open question, shown only while recording.
    private var question: ChattyConversation.Question? {
        model.isRecording ? model.openQuestion : nil
    }

    private var contentHeight: CGFloat {
        var h = Island.contentHeight
        if case let .done(result) = model.controller.state, result.liveModel != nil { h += Island.extraLineHeight }
        h += CGFloat(visibleRows) * Island.rowHeight
        if model.isReviewing { h += Island.footerHeight }
        if question != nil { h += Island.questionHeight }
        return h
    }

    /// The top row (status, title, buttons): the island's base height minus its vertical padding.
    private var headerHeight: CGFloat {
        var h = Island.contentHeight - 18
        if case let .done(result) = model.controller.state, result.liveModel != nil { h += Island.extraLineHeight }
        return h
    }

    /// Green when ready for the next point, red while listening or waiting for the live AI.
    private var border: Color? {
        guard model.isRecording else { return nil }
        return model.isReady ? .green : .red
    }

    var body: some View {
        let shape = IslandShape(flare: Island.flare, radius: Island.cornerRadius)
        VStack(spacing: 0) {
            IslandContent(model: model, close: close)
                .frame(height: headerHeight)
            if let question {
                QuestionBar(question: question, model: model)
            }
            if visibleRows > 0 || model.isReviewing {
                FeedList(model: model, visibleRows: visibleRows)
            }
            if model.isReviewing { ReviewFooter(model: model) }
        }
            .padding(.top, topInset + 8)
            .padding(.bottom, 10)
            .padding(.horizontal, Island.flare + 20)
            .frame(width: Island.width, height: topInset + contentHeight, alignment: .top)
            .background(shape.fill(.black))
            .overlay(shape.stroke(border ?? .clear, lineWidth: 2.5).opacity(border == nil ? 0 : 0.9))
            .animation(.easeInOut(duration: 0.25), value: border)
            .frame(maxHeight: .infinity, alignment: .top)
            .onAppear { resize(topInset + contentHeight) }
            .onChange(of: contentHeight) { _, h in resize(topInset + h) }
            .environment(\.colorScheme, .dark)
            .scaleEffect(x: presence.shown ? 1 : 0.35, y: presence.shown ? 1 : 0.1, anchor: .top)
            .opacity(presence.shown ? 1 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: presence.shown)
            .animation(.snappy, value: model.controller.state)
            .animation(.snappy, value: model.openQuestion)
    }
}

private struct IslandContent: View {
    let model: AppModel
    let close: () -> Void
    @State private var confirmCancel = false
    @State private var copiedAgain = false

    var body: some View {
        HStack(spacing: 12) {
            switch model.controller.state {
            case let .recording(mode, startedAt):
                RecordingDot()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Recording").font(.system(size: 13, weight: .semibold))
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(Duration.seconds(ctx.date.timeIntervalSince(startedAt)).formatted(.time(pattern: .minuteSecond)))
                                .monospacedDigit()
                        }
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        if mode != .manual { Text(mode.title).font(.system(size: 11)).foregroundStyle(.secondary) }
                        if mode != .manual { LiveStatusBadge(status: model.liveStatus) }
                    }
                    Group {
                        if !model.partialTranscript.isEmpty {
                            Text(model.partialTranscript).foregroundStyle(.secondary)
                        } else if model.isSpeaking {
                            Text("Speaking…").foregroundStyle(Color(cgColor: Palette.ai))
                        } else if model.openQuestion != nil {
                            Text("Click an answer below, or say it.").foregroundStyle(Color(cgColor: Palette.ai))
                        } else if model.feed.isWaiting {
                            Text("Marking it up…").foregroundStyle(.red)
                        } else {
                            Text(model.feed.entries.isEmpty ? "Ready. Talk about what you see. Hold ⌥ to draw." : "Ready for the next point.")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.isSpeaking {
                    Button("Stop talking") { model.stopTalking() }
                        .buttonStyle(IslandButtonStyle())
                }
                Button(confirmCancel ? "Discard?" : "Cancel") {
                    if confirmCancel { Task { await model.cancel() } } else {
                        confirmCancel = true
                        Task { try? await Task.sleep(for: .seconds(3)); confirmCancel = false }
                    }
                }
                .buttonStyle(IslandButtonStyle())
                Button("Stop") { Task { await model.toggleSession() } }
                    .buttonStyle(IslandButtonStyle(prominent: true))
            case .reviewing:
                Image(systemName: "checklist").font(.system(size: 18)).foregroundStyle(.white)
                titled("Review · \(model.feed.entries.count) point\(model.feed.entries.count == 1 ? "" : "s")",
                       model.feed.entries.isEmpty ? "Nothing was said. Copy writes up your marks." : "Untick anything you don't want, then copy.")
                Button(action: { model.closeReview() }) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close without copying (the session is kept)")
            case .finalizing:
                ProgressView().controlSize(.small)
                titled("Writing report…", "Claude is turning your notes into a write-up.")
            case let .done(result):
                let remote = model.settings.pasteForOtherComputer
                Image(systemName: result.usedAI ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 20)).foregroundStyle(result.usedAI ? .green : .yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.usedAI ? "Feedback ready · \(result.itemCount) item\(result.itemCount == 1 ? "" : "s")" : result.error == nil ? "No feedback captured" : "Saved without AI write-up")
                        .font(.system(size: 13, weight: .semibold))
                    Text(remote ? pasteHint
                         : result.usedAI ? "Prompt copied. Paste into Claude Code." : "Prompt copied. Screenshots and transcript are saved.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if result.usedAI, let usedModel = result.model {
                        Text(Pricing.summary(model: usedModel, tokens: result.tokens))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    if let liveModel = result.liveModel {
                        Text("Live: " + Pricing.summary(model: liveModel, tokens: result.liveTokens))
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let folder = model.controller.lastFolder {
                    Button(copiedAgain ? "Copied ✓" : "Copy Again") {
                        if !(remote && model.copyWriteup(folder: folder.url)) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result.prompt, forType: .string)
                        }
                        if !remote { copiedAgain = true }   // in paste mode the hint shows progress
                    }
                    .buttonStyle(IslandButtonStyle(prominent: true))
                    Button("Open Folder") { NSWorkspace.shared.open(folder.url) }
                        .buttonStyle(IslandButtonStyle())
                }
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close")
            default:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
    }

    private var pasteHint: String {
        switch model.paste.step {
        case .text: "⌘V in Claude to paste the write-up (1 of 2)"
        case .screenshots: "⌘V again to add the screenshots (2 of 2)"
        case .done: "All pasted. Send it in Claude."
        case nil: "Write-up copied. Paste into Claude."
        }
    }

    private func titled(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RecordingDot: View {
    @State private var pulse = false
    var body: some View {
        Circle().fill(.red).frame(width: 9, height: 9)
            .opacity(pulse ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// Live annotation health next to the timer: a pulsing blue dot while Claude is looking, nothing
/// while idle or fine, and an orange dot plus "AI offline" when the last request failed.
private struct LiveStatusBadge: View {
    let status: LiveStatus
    var body: some View {
        switch status {
        case .working:
            PulsingDot(color: Color(cgColor: Palette.ai), size: 7)
                .help("Claude is looking at your screen")
        case .offline:
            HStack(spacing: 4) {
                Circle().fill(.orange).frame(width: 7, height: 7)
                Text("AI offline").font(.system(size: 11)).foregroundStyle(.orange)
            }
            .help("The last Live request failed. Recording continues.")
        case .idle, .ok:
            EmptyView()
        }
    }
}

private struct PulsingDot: View {
    let color: Color
    let size: CGFloat
    @State private var pulse = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(pulse ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

/// Chatty's open question: the question, a button per answer option, and Skip. Saying the answer works too;
/// the question closes by itself after 20 s.
private struct QuestionBar: View {
    let question: ChattyConversation.Question
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(Color(cgColor: Palette.ai))
                Text(question.text).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.tail)
            }
            HStack(spacing: 8) {
                ForEach(question.options, id: \.self) { option in
                    Button(option) { model.answerQuestion(question.id, option) }
                        .buttonStyle(IslandButtonStyle(prominent: true))
                }
                Button("Skip") { model.skipQuestion(question.id) }
                    .buttonStyle(IslandButtonStyle())
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: Island.questionHeight, maxHeight: Island.questionHeight, alignment: .leading)
        .help("Click an answer or say it")
    }
}

private struct IslandButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(prominent ? .black : .white)
            .background(Capsule().fill(prominent ? Color.white : Color.white.opacity(0.16)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .fixedSize()
    }
}

/// The running list of sentences, each with the screenshot it goes with. Tickable in review.
private struct FeedList: View {
    let model: AppModel
    let visibleRows: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.feed.entries) { entry in
                        FeedRow(entry: entry, reviewing: model.isReviewing).id(entry.id)
                    }
                }
            }
            .scrollIndicators(model.isReviewing ? .automatic : .hidden)
            .frame(height: CGFloat(visibleRows) * Island.rowHeight)
            .onChange(of: model.feed.entries.count) {
                if let last = model.feed.entries.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }
}

private struct FeedRow: View {
    let entry: FeedEntry
    let reviewing: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if reviewing {
                Image(systemName: entry.included ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(entry.included ? Color.green : Color.white.opacity(0.4))
            } else {
                Circle().fill(.white.opacity(0.5)).frame(width: 5, height: 5)
            }
            thumbnail
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.included || !reviewing ? .white : .white.opacity(0.4))
                    .lineLimit(2)
                if !entry.captions.isEmpty {
                    Text(entry.captions.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Color(cgColor: Palette.ai)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Island.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { if reviewing { entry.included.toggle() } }
        .opacity(reviewing && !entry.included ? 0.7 : 1)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08))
            if let image = entry.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            }
            if entry.pending {
                Color.black.opacity(0.35)
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Selection count and the Copy button, under the list in review.
private struct ReviewFooter: View {
    let model: AppModel
    @State private var copying = false

    var body: some View {
        let total = model.feed.entries.count
        let chosen = model.feed.includedIDs.count
        HStack(spacing: 10) {
            if total > 0 {
                Text("\(chosen) of \(total) selected").font(.system(size: 12)).foregroundStyle(.secondary)
                Button(chosen == total ? "Select None" : "Select All") { model.feed.setAll(included: chosen != total) }
                    .buttonStyle(IslandButtonStyle())
            }
            Spacer()
            Button(copying ? "Writing…" : "Copy to Clipboard") {
                copying = true
                Task { await model.copySelected(); copying = false }
            }
            .buttonStyle(IslandButtonStyle(prominent: true))
            .disabled(copying || (total > 0 && chosen == 0))
        }
        .frame(height: Island.footerHeight)
    }
}
