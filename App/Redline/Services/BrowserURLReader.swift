import AppKit

enum BrowserURLReader {
    private static let scripts: [String: String] = [
        "com.google.Chrome": chromium("com.google.Chrome"),
        "company.thebrowser.Browser": chromium("company.thebrowser.Browser"),
        "com.apple.Safari": bounded(#"tell application id "com.apple.Safari" to get {URL, name} of front document"#),
    ]

    private static func chromium(_ id: String) -> String {
        bounded(#"tell application id "\#(id)" to get {URL, title} of active tab of front window"#)
    }

    /// Bounds the Apple Event wait so a hung or launching browser can't stall the main thread.
    private static func bounded(_ body: String) -> String {
        "with timeout of 1 second\n\(body)\nend timeout"
    }

    static func supports(_ bundleID: String) -> Bool { scripts[bundleID] != nil }

    /// The supported browser to read: the frontmost app if it is one, otherwise the browser whose
    /// window is highest on screen (e.g. Chrome on one display while the Claude app has focus).
    @MainActor static func browserToRead() -> String? {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, supports(front) { return front }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {   // front to back
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { continue }
            if supports(id) { return id }
        }
        return nil
    }

    /// Returns nil for unsupported apps, no window, or denied Automation permission.
    @MainActor static func read(bundleID: String) -> (url: String, title: String?)? {
        guard let source = scripts[bundleID], let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, result.numberOfItems >= 1, let url = result.atIndex(1)?.stringValue, !url.isEmpty else { return nil }
        return (url, result.atIndex(2)?.stringValue)
    }
}
