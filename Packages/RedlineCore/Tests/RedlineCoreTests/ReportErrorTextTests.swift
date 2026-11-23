import Foundation
import Testing
@testable import RedlineCore

@Test func describes401And403AsKeyProblem() {
    #expect(ReportErrorText.describe(ClaudeError.http(status: 401, body: "{\"x\":1}")) == "Claude rejected the API key. Check it in Settings.")
    #expect(ReportErrorText.describe(ClaudeError.http(status: 403, body: "")) == "Claude rejected the API key. Check it in Settings.")
}

@Test func describes429() {
    #expect(ReportErrorText.describe(ClaudeError.http(status: 429, body: "x")) == "Claude is rate-limiting requests. Try Regenerate in a minute.")
}

@Test func describesOtherHTTPWithoutBody() {
    let text = ReportErrorText.describe(ClaudeError.http(status: 500, body: "secret body"))
    #expect(text == "Claude API error (HTTP 500).")
}

@Test func describesRefusalTruncatedAndUnexpected() {
    #expect(ReportErrorText.describe(ClaudeError.refusal) == "Claude declined to write this report.")
    #expect(ReportErrorText.describe(ClaudeError.truncated) == "The report was cut off (too long).")
    #expect(ReportErrorText.describe(ClaudeError.noText) == "Claude returned an unexpected response.")
    #expect(ReportErrorText.describe(ClaudeError.invalidJSON("zzz")) == "Claude returned an unexpected response.")
}

@Test func describesURLErrorAndOthers() {
    let e = URLError(.notConnectedToInternet)
    #expect(ReportErrorText.describe(e) == "Network error: \(e.localizedDescription)")
    struct Other: Error {}
    #expect(ReportErrorText.describe(Other()) == "Couldn't write the AI report.")
}
