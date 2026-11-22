import Foundation

public enum ReportErrorText {
    public static func describe(_ error: Error) -> String {
        if let e = error as? ClaudeError {
            switch e {
            case let .http(status, _):
                switch status {
                case 401, 403: return "Claude rejected the API key. Check it in Settings."
                case 429: return "Claude is rate-limiting requests. Try Regenerate in a minute."
                default: return "Claude API error (HTTP \(status))."
                }
            case .refusal: return "Claude declined to write this report."
            case .truncated: return "The report was cut off (too long)."
            case .noText, .invalidJSON: return "Claude returned an unexpected response."
            }
        }
        if error is URLError { return "Network error: \(error.localizedDescription)" }
        return "Couldn't write the AI report."
    }
}
