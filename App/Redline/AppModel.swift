import Observation

@MainActor @Observable
final class AppModel {
    var isRecording = false
    func launch() {}
}
