import Testing
import Foundation
@testable import RedlineCore

final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (Int, String) = (200, "{}")
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.response
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func stubbedClient() -> ClaudeHTTPClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return ClaudeHTTPClient(apiKey: "sk-test", session: URLSession(configuration: config))
}

private func sampleInput() -> ReportInput {
    var m = Moment(id: 1, start: 0, end: 2, sentences: [SentenceRef(id: UUID(), text: "too cramped", start: 0, end: 2)])
    m.url = "http://localhost:3000/billing"
    return ReportInput(moments: [m], images: [1: Data([0xFF, 0xD8, 0xFF])],
                       transcript: [TranscriptLine(t: 0, text: "too cramped")], startURL: "http://localhost:3000/")
}

@Suite(.serialized) struct ClaudeClientTests {
    @Test func requestHasHeadersAndStructuredOutput() throws {
        let req = try stubbedClient().makeURLRequest(ReportRequest.make(model: "claude-sonnet-5-5", input: sampleInput()))
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        let bodyData = try #require(req.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["tool_choice"] == nil && body["temperature"] == nil)
        let oc = try #require(body["output_config"] as? [String: Any])
        #expect(oc["effort"] as? String == "medium")
        #expect((oc["format"] as? [String: Any])?["type"] as? String == "json_schema")
        let content = try #require(((body["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        let image = try #require(content.first { $0["type"] as? String == "image" })
        let source = try #require(image["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64" && source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == Data([0xFF, 0xD8, 0xFF]).base64EncodedString())
    }

    @Test func parsesTextResponse() async throws {
        StubProtocol.response = (200, #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"items\":[]}"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":3}}"#)
        let r = try await stubbedClient().send(ReportRequest.make(model: "claude-sonnet-5-5", input: sampleInput()))
        #expect(r.firstText() == #"{"items":[]}"#)
        #expect(r.usage?.input_tokens == 10)
    }

    @Test func httpErrorAndRefusalThrow() async {
        StubProtocol.response = (401, #"{"error":{"message":"bad key"}}"#)
        await #expect(throws: ClaudeError.http(status: 401, body: #"{"error":{"message":"bad key"}}"#)) {
            try await stubbedClient().send(ReportRequest.make(model: "m", input: sampleInput()))
        }
        StubProtocol.response = (200, #"{"content":[],"stop_reason":"refusal"}"#)
        await #expect(throws: ClaudeError.refusal) {
            try await stubbedClient().send(ReportRequest.make(model: "m", input: sampleInput()))
        }
    }
}

@Test func parseFiltersUnknownMomentsAndEmptyTitles() throws {
    let text = #"{"items":[{"title":"Fix padding","moment_ids":[1,9],"where":"/billing","problem":"p","wanted":"w","quote":"q","image_caption":""},{"title":" ","moment_ids":[1],"where":"","problem":"","wanted":"","quote":"","image_caption":""}]}"#
    let items = try ReportRequest.parse(text, validMomentIDs: [1])
    #expect(items.count == 1)
    #expect(items[0].momentIDs == [1])
}

@Test func parseRejectsGarbage() {
    #expect(throws: ClaudeError.self) { try ReportRequest.parse("not json", validMomentIDs: [1]) }
}
