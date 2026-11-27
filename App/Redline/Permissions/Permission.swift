import AVFoundation
import AppKit
import CoreGraphics
import ScreenCaptureKit
import Speech

enum Permission: String, CaseIterable, Identifiable {
    case screenRecording, microphone, speech, inputMonitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .microphone: "Microphone"
        case .speech: "Speech Recognition"
        case .inputMonitoring: "Input Monitoring"
        }
    }

    var reason: String {
        switch self {
        case .screenRecording: "Takes screenshots of the app you're reviewing."
        case .microphone: "Hears your narration. Audio is never saved."
        case .speech: "Turns your narration into text on this Mac."
        case .inputMonitoring: "Notices clicks and the ⌥ pen key while you record."
        }
    }

    var settingsURL: URL {
        let anchor = switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .microphone: "Privacy_Microphone"
        case .speech: "Privacy_SpeechRecognition"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// Live check. `CGPreflightScreenCaptureAccess` and `CGPreflightListenEventAccess` cache their
    /// answer for the life of the process, so a grant made in System Settings while Redline is
    /// running only shows up after a relaunch. When the cached answer is "no", ask the real
    /// subsystem instead: ScreenCaptureKit for Screen Recording, a throwaway listen-only event
    /// tap for Input Monitoring.
    @MainActor func isGranted() async -> Bool {
        switch self {
        case .screenRecording:
            if CGPreflightScreenCaptureAccess() { return true }
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                return true
            } catch {
                return false
            }
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech:
            return SFSpeechRecognizer.authorizationStatus() == .authorized
        case .inputMonitoring:
            if CGPreflightListenEventAccess() { return true }
            return Self.canCreateListenTap()
        }
    }

    /// Creating a listen-only tap succeeds only when Input Monitoring is granted, and the answer is
    /// not cached per process. The tap is invalidated immediately.
    private static func canCreateListenTap() -> Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.flagsChanged.rawValue),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil) else { return false }
        CFMachPortInvalidate(tap)
        return true
    }

    @MainActor func request() async {
        switch self {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .speech:
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
            }
        case .inputMonitoring:
            _ = CGRequestListenEventAccess()
        }
        if await !isGranted() { NSWorkspace.shared.open(settingsURL) }
    }

    @MainActor static func missing() async -> [Permission] {
        var out: [Permission] = []
        for p in allCases where await !p.isGranted() { out.append(p) }
        return out
    }

    /// Quit and start a fresh copy of this same app bundle, so the cached permission answers reset.
    @MainActor static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
