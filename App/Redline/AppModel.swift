import Foundation
import KeyboardShortcuts
import Observation

@MainActor @Observable
final class AppModel {
    let settings = AppSettings()
    var isRecording = false
    @ObservationIgnored private let onboarding = OnboardingWindowController()

    func launch() {
        KeyboardShortcuts.onKeyUp(for: .toggleSession) { NSLog("Redline: toggle hotkey") }
        KeyboardShortcuts.onKeyUp(for: .markMoment) { NSLog("Redline: mark hotkey") }
        if !Permission.missing.isEmpty { onboarding.show() }
    }

    func showOnboarding() { onboarding.show() }
}
