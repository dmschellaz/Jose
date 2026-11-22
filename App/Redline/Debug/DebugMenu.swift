#if DEBUG
import RedlineCore
import SwiftUI

struct DebugMenu: View {
    let model: AppModel
    var body: some View {
        Menu("Debug") {
            Button("Capture keyframe in 3 s") {
                Task {
                    let capture = CaptureService()
                    await DebugHarness.run([capture], seconds: 0.5, title: "Capture") { _ in
                        try? await Task.sleep(for: .seconds(3))
                        _ = await capture.captureKeyframe(reason: .mark)
                    }
                }
            }
            Button("Transcribe 10 s") {
                Task { await DebugHarness.run([SpeechService()], seconds: 10, title: "Speech") }
            }
            Button("Context 15 s") {
                Task {
                    let ctx = ContextService()
                    ctx.onPen = { NSLog("Redline: pen \($0 ? "down" : "up")") }
                    await DebugHarness.run([ctx], seconds: 15, title: "Context")
                }
            }
        }
    }
}
#endif
