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

@MainActor @Observable
private final class PermissionChecker {
    var granted: [Permission: Bool] = [:]
    var checking = false

    func refresh() async {
        checking = true
        var next: [Permission: Bool] = [:]
        for p in Permission.allCases { next[p] = await p.isGranted() }
        granted = next
        checking = false
    }
}

private struct OnboardingView: View {
    @State private var checker = PermissionChecker()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Redline needs a few permissions").font(.title2.bold())
            ForEach(Permission.allCases) { p in
                let ok = checker.granted[p] ?? false
                HStack(alignment: .top) {
                    Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(ok ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(p.title).bold()
                        Text(p.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !ok {
                        Button("Grant") { Task { await p.request(); await checker.refresh() } }
                    }
                }
            }
            Text("Already switched on in System Settings but still unchecked here? macOS ties each permission to the exact build of Redline. Open that list, select Redline, remove it with the – button, then click Grant again.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Quit & Reopen Redline") { Permission.relaunch() }
                Spacer()
                if checker.checking { ProgressView().controlSize(.small) }
                Button("Re-check") { Task { await checker.refresh() } }
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await checker.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checker.refresh() }
        }
    }
}
