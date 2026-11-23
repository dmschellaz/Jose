import Foundation

public enum Slug {
    /// Lowercase, alphanumeric words joined by "-", first `maxWords` words. Returns "item" if nothing is left.
    public static func make(_ s: String, maxWords: Int = 3) -> String {
        let words = s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(maxWords)
        return words.isEmpty ? "item" : words.joined(separator: "-")
    }
}

public struct SessionFolder: Sendable, Equatable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public var rawURL: URL { url.appending(path: "raw", directoryHint: .isDirectory) }
    public var feedbackURL: URL { url.appending(path: "feedback.md") }
    public var documentURL: URL { url.appending(path: "session.json") }

    /// "localhost-3000" for http://localhost:3000/…, "myapp-com" for https://www.myapp.com, "session" otherwise.
    public static func slug(fromURL string: String?) -> String {
        guard let string, let comps = URLComponents(string: string), var host = comps.host, !host.isEmpty else {
            return "session"
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let base = comps.port.map { "\(host)-\($0)" } ?? host
        return Slug.make(base, maxWords: 4)
    }

    public static func folderName(slug: String, date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(slug)-\(f.string(from: date))"
    }

    /// Creates `<root>/<slug>-<date>[-N]/raw/`.
    public static func create(root: URL, slug: String, date: Date, timeZone: TimeZone = .current) throws -> SessionFolder {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = uniqueURL(root: root, name: folderName(slug: slug, date: date, timeZone: timeZone))
        let folder = SessionFolder(url: url)
        try fm.createDirectory(at: folder.rawURL, withIntermediateDirectories: true)
        return folder
    }

    /// Moves the folder to a name built from `slug`. Returns self if the name is unchanged.
    public func renamed(slug: String, date: Date, timeZone: TimeZone = .current) throws -> SessionFolder {
        let name = Self.folderName(slug: slug, date: date, timeZone: timeZone)
        if url.lastPathComponent == name { return self }
        let target = Self.uniqueURL(root: url.deletingLastPathComponent(), name: name)
        try FileManager.default.moveItem(at: url, to: target)
        return SessionFolder(url: target)
    }

    private static func uniqueURL(root: URL, name: String) -> URL {
        var candidate = root.appending(path: name, directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appending(path: "\(name)-\(n)", directoryHint: .isDirectory)
            n += 1
        }
        return candidate
    }
}
