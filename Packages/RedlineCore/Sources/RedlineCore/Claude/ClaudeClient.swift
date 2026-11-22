import Foundation

public enum ContentBlock: Encodable, Equatable, Sendable {
    case text(String)
    case jpeg(Data)

    private enum Keys: String, CodingKey { case type, text, source }
    private struct Source: Encodable {
        let type = "base64"
        let media_type = "image/jpeg"
        let data: String
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .text(s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case let .jpeg(d):
            try c.encode("image", forKey: .type)
            try c.encode(Source(data: d.base64EncodedString()), forKey: .source)
        }
    }
}

/// Field names match the wire format exactly (snake_case is intentional).
public struct MessagesRequest: Encodable, Sendable {
    public struct Message: Encodable, Sendable {
        public var role: String
        public var content: [ContentBlock]
    }
    public struct Format: Encodable, Sendable {
        public var type = "json_schema"
        public var schema: JSONValue
    }
    public struct OutputConfig: Encodable, Sendable {
        public var effort: String?
        public var format: Format?
    }

    public var model: String
    public var max_tokens: Int
    public var system: String?
    public var messages: [Message]
    public var output_config: OutputConfig?
    /// "default" enables server-side refusal fallbacks (needs the beta header).
    public var fallbacks: String?
}

public struct MessagesResponse: Decodable, Sendable {
    public struct Block: Decodable, Sendable {
        public var type: String
        public var text: String?
    }
    public struct Usage: Decodable, Sendable {
        public var input_tokens: Int
        public var output_tokens: Int
    }
    public var content: [Block]
    public var stop_reason: String?
    public var usage: Usage?

    public func firstText() -> String? {
        content.first { $0.type == "text" }?.text
    }
}

public protocol LLMClient: Sendable {
    func send(_ request: MessagesRequest) async throws -> MessagesResponse
}

public enum ClaudeError: Error, Equatable {
    case http(status: Int, body: String)
    case refusal
    case truncated
    case noText
    case invalidJSON(String)
}

public struct ClaudeHTTPClient: LLMClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    public static let fallbackBeta = "server-side-fallback-2026-07-01"

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public func makeURLRequest(_ request: MessagesRequest) throws -> URLRequest {
        var r = URLRequest(url: Self.endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 180
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        r.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if request.fallbacks != nil {
            r.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        r.httpBody = try JSONEncoder().encode(request)
        return r
    }

    public func send(_ request: MessagesRequest) async throws -> MessagesResponse {
        let (data, response) = try await session.data(for: makeURLRequest(request))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ClaudeError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        switch decoded.stop_reason {
        case "refusal": throw ClaudeError.refusal
        case "max_tokens": throw ClaudeError.truncated
        default: return decoded
        }
    }
}
