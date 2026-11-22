import AppKit

enum BrowserURLReader {
    private static let scripts: [String: String] = [
        "com.google.Chrome": #"tell application id "com.google.Chrome" to get {URL, title} of active tab of front window"#,
        "company.thebrowser.Browser": #"tell application id "company.thebrowser.Browser" to get {URL, title} of active tab of front window"#,
        "com.apple.Safari": #"tell application id "com.apple.Safari" to get {URL, name} of front document"#,
    ]

    static func supports(_ bundleID: String) -> Bool { scripts[bundleID] != nil }

    /// Returns nil for unsupported apps, no window, or denied Automation permission.
    @MainActor static func read(bundleID: String) -> (url: String, title: String?)? {
        guard let source = scripts[bundleID], let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems >= 1, let url = result.atIndex(1)?.stringValue, !url.isEmpty else { return nil }
        return (url, result.atIndex(2)?.stringValue)
    }
}
