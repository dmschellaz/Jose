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
            Button("Mic gate 10 s (deaf 3–7 s)") {
                Task {
                    let speech = SpeechService()
                    await DebugHarness.run([speech], seconds: 10, title: "Mic gate") { _ in
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(3))
                            speech.gate.close()
                            try? await Task.sleep(for: .seconds(4))
                            speech.gate.open()
                        }
                    }
                }
            }
            Button("Chatty voice + mic gate 12 s") {
                Task {
                    let speech = SpeechService()
                    let voice = VoiceService(gate: speech.gate)
                    await DebugHarness.run([speech, voice], seconds: 12, title: "Chatty voice", mode: .chatty) { _ in
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(2))
                            voice.speak("This line is spoken by Redline and should not be transcribed.")
                        }
                    }
                }
            }
            Button("Context 15 s") {
                Task {
                    let ctx = ContextService()
                    ctx.onPen = { NSLog("Redline: pen \($0 ? "down" : "up")") }
                    await DebugHarness.run([ctx], seconds: 15, title: "Context")
                }
            }
            Button("Overlay + pen 20 s") {
                Task {
                    let overlay = OverlayController()
                    let ctx = ContextService()
                    ctx.onPen = { overlay.setPen($0) }
                    await DebugHarness.run([overlay, ctx], seconds: 20, title: "Overlay") { _ in
                        let d = NSScreen.main?.displayID ?? 0
                        let b = CGDisplayBounds(d)
                        overlay.display(Annotation(shape: .circle(center: CGPoint(x: b.midX, y: b.midY), radius: 80),
                                                   caption: "Billing card padding", author: .ai, createdAt: 0, displayID: d), lifetime: 6)
                    }
                }
            }
        }
    }
}
#endif
