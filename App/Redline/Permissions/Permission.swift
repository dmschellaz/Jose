import AVFoundation
import AppKit
import CoreGraphics
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

    @MainActor var isGranted: Bool {
        switch self {
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .speech: SFSpeechRecognizer.authorizationStatus() == .authorized
        case .inputMonitoring: CGPreflightListenEventAccess()
        }
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
        if !isGranted { NSWorkspace.shared.open(settingsURL) }
    }

    @MainActor static var missing: [Permission] { allCases.filter { !$0.isGranted } }
}
