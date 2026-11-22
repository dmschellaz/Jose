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
        }
    }
}
#endif
