import Testing
import Foundation
@testable import RedlineCore

private let date = Date(timeIntervalSince1970: 1_763_821_800) // 2025-11-22 14:30 UTC

@Test func slugFromURL() {
    #expect(SessionFolder.slug(fromURL: "http://localhost:3000/settings") == "localhost-3000")
    #expect(SessionFolder.slug(fromURL: "https://www.MyApp.com/x") == "myapp-com")
    #expect(SessionFolder.slug(fromURL: nil) == "session")
    #expect(SessionFolder.slug(fromURL: "not a url") == "session")
}

@Test func slugMakeTakesFirstWords() {
    #expect(Slug.make("Billing card padding is too tight") == "billing-card-padding")
    #expect(Slug.make("  !!! ") == "item")
}

@Test func folderNameFormat() {
    #expect(SessionFolder.folderName(slug: "myapp", date: date, timeZone: .gmt) == "myapp-2025-11-22-1430")
}

@Test func createMakesRawDirAndAvoidsCollisions() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let a = try SessionFolder.create(root: root, slug: "s", date: date, timeZone: .gmt)
    let b = try SessionFolder.create(root: root, slug: "s", date: date, timeZone: .gmt)
    #expect(a.url.lastPathComponent == "s-2025-11-22-1430")
    #expect(b.url.lastPathComponent == "s-2025-11-22-1430-2")
    #expect(FileManager.default.fileExists(atPath: a.rawURL.path))
}

@Test func renameMovesContents() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let a = try SessionFolder.create(root: root, slug: "session", date: date, timeZone: .gmt)
    try Data("x".utf8).write(to: a.rawURL.appending(path: "k.png"))
    let b = try a.renamed(slug: "myapp", date: date, timeZone: .gmt)
    #expect(b.url.lastPathComponent == "myapp-2025-11-22-1430")
    #expect(FileManager.default.fileExists(atPath: b.rawURL.appending(path: "k.png").path))
    #expect(!FileManager.default.fileExists(atPath: a.url.path))
    #expect(try b.renamed(slug: "myapp", date: date, timeZone: .gmt) == b)
}
