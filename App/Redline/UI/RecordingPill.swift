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
            let size = NSSize(width: Island.width, height: topInset + Island.contentHeight)
            let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
            let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .statusBar   // above the menu bar, so the island sits flush with the top edge
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let hosting = NSHostingView(rootView: IslandView(model: model, presence: presence, topInset: topInset) { [weak self] in
                self?.hide()
            })
            hosting.safeAreaRegions = []
            p.contentView = hosting
            p.orderFrontRegardless()
            panel = p
        }
        presence.shown = true
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
    static let width: CGFloat = 600
    static let contentHeight: CGFloat = 76
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

    var body: some View {
        IslandContent(model: model, close: close)
            .padding(.top, topInset + 8)
            .padding(.bottom, 10)
            .padding(.horizontal, Island.flare + 20)
            .frame(width: Island.width, height: topInset + Island.contentHeight, alignment: .top)
            .background(IslandShape(flare: Island.flare, radius: Island.cornerRadius).fill(.black))
            .environment(\.colorScheme, .dark)
            .scaleEffect(x: presence.shown ? 1 : 0.35, y: presence.shown ? 1 : 0.1, anchor: .top)
            .opacity(presence.shown ? 1 : 0)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: presence.shown)
            .animation(.snappy, value: model.controller.state)
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
                    }
                    Text(model.partialTranscript.isEmpty ? "Listening… Hold ⌥ to draw." : model.partialTranscript)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(confirmCancel ? "Discard?" : "Cancel") {
                    if confirmCancel { Task { await model.cancel() } } else {
                        confirmCancel = true
                        Task { try? await Task.sleep(for: .seconds(3)); confirmCancel = false }
                    }
                }
                .buttonStyle(IslandButtonStyle())
                Button("Stop") { Task { await model.toggleSession() } }
                    .buttonStyle(IslandButtonStyle(prominent: true))
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
                    Text(remote ? "Copied with screenshots. Paste into Claude."
                         : result.usedAI ? "Prompt copied. Paste into Claude Code." : "Prompt copied. Screenshots and transcript are saved.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if result.usedAI, let usedModel = result.model {
                        Text(Pricing.summary(model: usedModel, tokens: result.tokens))
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
                        copiedAgain = true
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
