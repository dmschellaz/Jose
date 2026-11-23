import Foundation

public enum SessionMode: String, Codable, CaseIterable, Sendable {
    case manual, live, chatty
    public var title: String { rawValue.capitalized }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int
    public var output: Int
    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }
}

public struct SessionMetadata: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var endedAt: Date?
    public var mode: SessionMode
    public var displays: [DisplayGeometry]
    public var tokens: TokenUsage

    public init(startedAt: Date, endedAt: Date?, mode: SessionMode, displays: [DisplayGeometry], tokens: TokenUsage) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.displays = displays
        self.tokens = tokens
    }
}

public struct SessionDocument: Codable, Equatable, Sendable {
    public var metadata: SessionMetadata
    public var events: [TimelineEvent]

    public init(metadata: SessionMetadata, events: [TimelineEvent]) {
        self.metadata = metadata
        self.events = events
    }
}

public enum SessionStore {
    public static func save(_ doc: SessionDocument, to folder: SessionFolder) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(doc).write(to: folder.documentURL, options: .atomic)
    }

    public static func load(from folder: SessionFolder) throws -> SessionDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionDocument.self, from: Data(contentsOf: folder.documentURL))
    }
}
