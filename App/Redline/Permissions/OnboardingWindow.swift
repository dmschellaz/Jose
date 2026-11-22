import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Redline Setup"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView())
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct OnboardingView: View {
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Redline needs a few permissions").font(.title2.bold())
            ForEach(Permission.allCases) { p in
                HStack(alignment: .top) {
                    Image(systemName: p.isGranted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(p.isGranted ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(p.title).bold()
                        Text(p.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !p.isGranted {
                        Button("Grant") { Task { await p.request(); refresh += 1 } }
                    }
                }
            }
            .id(refresh)
            Text("After granting Screen Recording or Input Monitoring, macOS may ask you to quit and reopen Redline. Do that, then click Re-check.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Re-check") { refresh += 1 }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
