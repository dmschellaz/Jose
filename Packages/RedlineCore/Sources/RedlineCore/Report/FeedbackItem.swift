import Foundation

public struct FeedbackItem: Codable, Equatable, Sendable {
    public var title: String
    public var momentIDs: [Int]
    public var location: String
    public var problem: String
    public var wanted: String
    public var quote: String
    public var imageCaption: String

    enum CodingKeys: String, CodingKey {
        case title, problem, wanted, quote
        case momentIDs = "moment_ids"
        case location = "where"
        case imageCaption = "image_caption"
    }

    public init(title: String, momentIDs: [Int], location: String, problem: String, wanted: String, quote: String, imageCaption: String) {
        self.title = title
        self.momentIDs = momentIDs
        self.location = location
        self.problem = problem
        self.wanted = wanted
        self.quote = quote
        self.imageCaption = imageCaption
    }
}

/// Used when there is no API key or the AI call fails: one item per moment.
public enum FallbackReport {
    public static func items(from moments: [Moment]) -> [FeedbackItem] {
        moments.map { m in
            FeedbackItem(title: "Moment \(m.id)", momentIDs: [m.id],
                         location: m.url.map(pathOf) ?? "Unknown page",
                         problem: "AI write-up unavailable. See the quote and screenshot.",
                         wanted: "", quote: m.text.isEmpty ? "(no speech)" : m.text, imageCaption: "")
        }
    }

    static func pathOf(_ url: String) -> String {
        guard let comps = URLComponents(string: url), !comps.path.isEmpty else { return url }
        return comps.path
    }
}
