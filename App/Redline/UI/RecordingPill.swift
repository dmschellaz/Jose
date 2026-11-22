#if PILL_READY
import AppKit
import RedlineCore
import SwiftUI

@MainActor
final class RecordingPillController {
    private var panel: NSPanel?

    func show(model: AppModel) {
        guard panel == nil, let screen = NSScreen.main else { return }
        let size = NSSize(width: 440, height: 44)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 8)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = NSHostingView(rootView: PillView(model: model))
        p.orderFrontRegardless()
        panel = p
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct PillView: View {
    let model: AppModel
    @State private var confirmCancel = false

    var body: some View {
        HStack(spacing: 10) {
            switch model.controller.state {
            case let .recording(mode, startedAt):
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(mode.title).font(.caption.bold())
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Duration.seconds(ctx.date.timeIntervalSince(startedAt)).formatted(.time(pattern: .minuteSecond)))
                        .monospacedDigit().font(.caption)
                }
                Text(model.partialTranscript.isEmpty ? "Listening…" : model.partialTranscript)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(confirmCancel ? "Discard?" : "Cancel") {
                    if confirmCancel { Task { await model.cancel() } } else {
                        confirmCancel = true
                        Task { try? await Task.sleep(for: .seconds(3)); confirmCancel = false }
                    }
                }
                .controlSize(.small)
                Button("Stop") { Task { await model.toggleSession() } }
                    .controlSize(.small).buttonStyle(.borderedProminent)
            case .finalizing:
                ProgressView().controlSize(.small)
                Text("Writing report…").font(.caption)
                Spacer()
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 440, height: 44)
        .background(.regularMaterial, in: Capsule())
    }
}
#endif
