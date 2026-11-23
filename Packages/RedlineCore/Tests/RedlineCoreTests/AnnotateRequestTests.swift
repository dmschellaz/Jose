import Testing
import Foundation
import CoreGraphics
@testable import RedlineCore

/// A 1000x500 pt display at (-1000, 200), captured into a 1280x640 px image (1.28 px per pt).
func liveTestFrame(t: Double = 1) -> LiveFrame {
    LiveFrame(jpeg: Data([0xFF, 0xD8, 0xFF]), pixelSize: CGSize(width: 1280, height: 640),
              display: DisplayGeometry(id: 7, frame: CGRect(x: -1000, y: 200, width: 1000, height: 500), scale: 2), t: t)
}

private func json(_ request: MessagesRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
}

private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001 }
private func near(_ a: CGRect, _ b: CGRect) -> Bool {
    near(a.origin, b.origin) && abs(a.width - b.width) < 0.001 && abs(a.height - b.height) < 0.001
}

@Suite struct AnnotateRequestTests {
    @Test func requestShapeForHaiku() throws {
        let frame = liveTestFrame()
        let req = AnnotateRequest.make(model: "claude-haiku-5-5", frame: frame, sentence: "this button is too small",
                                       recentSentences: ["ok the header"], clicks: [CGPoint(x: -500, y: 450)],
                                       url: "http://localhost:3000/")
        let body = try json(req)
        #expect(body["model"] as? String == "claude-haiku-5-5")
        #expect(body["max_tokens"] as? Int == 2000)
        #expect(body["fallbacks"] == nil)
        #expect(body["tool_choice"] == nil)
        let oc = try #require(body["output_config"] as? [String: Any])
        #expect(oc["effort"] as? String == "low")
        let format = try #require(oc["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let content = try #require(((body["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        #expect(content.contains { $0["type"] as? String == "image" })
        let text = content.compactMap { $0["text"] as? String }.joined()
        // (-500, 450) is the display's center → (640, 320) in image px.
        #expect(text.contains("(640, 320)"))
        #expect(text.contains("this button is too small"))
        #expect(text.contains("ok the header"))
        #expect(text.contains("http://localhost:3000/"))
    }

    @Test func fallbacksOnlyForSonnet() throws {
        let req = AnnotateRequest.make(model: "claude-sonnet-5-5", frame: liveTestFrame(), sentence: "x",
                                       recentSentences: [], clicks: [], url: nil)
        #expect(req.fallbacks == "default")
        #expect(try ClaudeHTTPClient(apiKey: "k").makeURLRequest(req).value(forHTTPHeaderField: "anthropic-beta") != nil)
    }

    @Test func thinkingIsOffForLiveModels() throws {
        let frame = liveTestFrame()
        func body(_ model: String) throws -> [String: Any] {
            try json(AnnotateRequest.make(model: model, frame: frame, sentence: "s", recentSentences: [], clicks: [], url: nil))
        }
        #expect((try body("claude-haiku-5-5")["thinking"] as? [String: String]) == ["type": "disabled"])
        #expect((try body("claude-sonnet-5-5")["thinking"] as? [String: String]) == ["type": "between_tools"])
        #expect(AnnotateRequest.systemPrompt.contains("change the reviewer is asking for"))
    }

    @Test func normalizedSentenceMatching() {
        let n = LiveAnnotator.normalize
        #expect(n("Make THIS purple, please.") == "make this purple please")
        #expect(LiveAnnotator.sameSentence(n("make this purple"), n("Make this purple.")))
        #expect(LiveAnnotator.sameSentence(n("show the rolling twelve months"), n("Show the rolling twelve months here.")))
        #expect(!LiveAnnotator.sameSentence(n("so this one"), n("So this one should be much bigger and bold.")))
    }

    @Test func schemaIsStrict() throws {
        guard case let .object(root) = AnnotateRequest.schema,
              case let .object(props)? = root["properties"],
              case let .object(marks)? = props["marks"],
              case let .object(mark)? = marks["items"],
              case let .array(required)? = mark["required"],
              case let .object(markProps)? = mark["properties"] else { Issue.record("bad schema"); return }
        #expect(mark["additionalProperties"] == .bool(false))
        #expect(root["additionalProperties"] == .bool(false))
        #expect(Set(required.compactMap { if case let .string(s) = $0 { s } else { nil } }) == Set(markProps.keys))
        #expect(markProps.count == 6)
    }

    // liveTestFrame: 1280×640 px over a 1000×500 pt display at (-1000, 200), so 1.28 px per point.
    @Test func parseDrawsEveryShapeAroundTheBox() throws {
        let text = """
        {"marks":[
          {"shape":"circle","x":576,"y":256,"w":128,"h":128,"caption":" Save button "},
          {"shape":"rect","x":128,"y":64,"w":256,"h":128,"caption":"Header"},
          {"shape":"highlight","x":128,"y":64,"w":256,"h":0,"caption":"Title text"},
          {"shape":"arrow","x":640,"y":320,"w":64,"h":32,"caption":""}
        ]}
        """
        let marks = try AnnotateRequest.parse(text, frame: liveTestFrame(), createdAt: 4.5)
        #expect(marks.count == 3)   // capped at maxMarks
        #expect(marks.allSatisfy { $0.author == .ai && $0.displayID == 7 && $0.createdAt == 4.5 })
        guard case let .circle(c, r) = marks[0].shape else { Issue.record("not circle"); return }
        #expect(near(c, CGPoint(x: -500, y: 450)))
        #expect(abs(r - (64 * 1.15 + 4) / 1.28) < 0.001)
        #expect(marks[0].caption == "Save button")
        guard case let .rect(rect) = marks[1].shape else { Issue.record("not rect"); return }
        #expect(near(rect, CGRect(x: -1000 + 124 / 1.28, y: 200 + 60 / 1.28, width: 264 / 1.28, height: 136 / 1.28)))
        // A zero-height highlight is widened to 16 px around its line instead of being dropped.
        guard case let .highlight(h) = marks[2].shape else { Issue.record("not highlight"); return }
        #expect(near(h, CGRect(x: -900, y: 200 + 56 / 1.28, width: 200, height: 12.5)))
    }

    @Test func arrowPointsAtTheBoxFromOutside() throws {
        let text = """
        {"marks":[
          {"shape":"arrow","x":640,"y":320,"w":64,"h":32,"caption":"Save"},
          {"shape":"arrow","x":20,"y":320,"w":64,"h":32,"caption":"Edge"}
        ]}
        """
        let marks = try AnnotateRequest.parse(text, frame: liveTestFrame(), createdAt: 0)
        guard case let .arrow(from, to) = marks[0].shape, case let .arrow(from2, to2) = marks[1].shape else {
            Issue.record("not arrows"); return
        }
        #expect(near(to, CGPoint(x: -1000 + 636 / 1.28, y: 200 + 336 / 1.28)))
        #expect(near(from, CGPoint(x: -1000 + 566 / 1.28, y: 200 + 296 / 1.28)))
        // No room on the left: it comes from the right instead.
        #expect(near(to2, CGPoint(x: -1000 + 88 / 1.28, y: 200 + 336 / 1.28)))
        #expect(from2.x > to2.x)
    }

    @Test func parseClampsToImageAndDropsBoxesWithNoPosition() throws {
        let text = """
        {"marks":[
          {"shape":"highlight","x":1200,"y":-40,"w":200,"h":104,"caption":"off edge"},
          {"shape":"rect","x":2000,"y":10,"w":50,"h":50,"caption":"outside"},
          {"shape":"circle","x":0,"y":0,"w":0,"h":0,"caption":"nowhere"},
          {"shape":"star","x":5,"y":5,"w":10,"h":10,"caption":"unknown"},
          {"shape":"circle","x":10,"y":10,"w":0,"h":0,"caption":"dot"}
        ]}
        """
        let marks = try AnnotateRequest.parse(text, frame: liveTestFrame(), createdAt: 1)
        #expect(marks.map(\.caption) == ["off edge", "dot"])
        guard case let .highlight(r) = marks[0].shape else { Issue.record("not highlight"); return }
        // Clamped to x 1200…1280, y 0…64 px → 62.5 x 50 pt at the display's top-right.
        #expect(near(r, CGRect(x: -62.5, y: 200, width: 62.5, height: 50)))
        guard case let .circle(c, _) = marks[1].shape else { Issue.record("not circle"); return }
        #expect(near(c, CGPoint(x: -1000 + 10 / 1.28, y: 200 + 10 / 1.28)))
    }

    @Test func parseCapsAtThreeMarks() throws {
        let one = #"{"shape":"rect","x":10,"y":10,"w":20,"h":20,"caption":"a"}"#
        let text = #"{"marks":["# + Array(repeating: one, count: 5).joined(separator: ",") + "]}"
        #expect(try AnnotateRequest.parse(text, frame: liveTestFrame(), createdAt: 0).count == 3)
    }

    @Test func parseEmptyMarks() throws {
        #expect(try AnnotateRequest.parse(#"{"marks":[]}"#, frame: liveTestFrame(), createdAt: 0).isEmpty)
    }

    @Test func malformedThrowsInvalidJSON() {
        #expect(throws: ClaudeError.invalidJSON("not json")) {
            try AnnotateRequest.parse("not json", frame: liveTestFrame(), createdAt: 0)
        }
        #expect(throws: ClaudeError.self) {
            try AnnotateRequest.parse(#"{"marks":[{"shape":"rect"}]}"#, frame: liveTestFrame(), createdAt: 0)
        }
    }
}
