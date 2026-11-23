import CoreFoundation

// Private CoreGraphics (SkyLight) calls. There is no public API that lets a background app set the
// cursor; this connection property is the long-standing workaround used by cursor and annotation
// utilities. Fine for a locally built app; not allowed on the Mac App Store.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ targetCID: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

@MainActor
enum BackgroundCursor {
    private static var enabled = false
    /// CGError from the last attempt (0 = success), or -1 if never attempted.
    private(set) static var lastResult: Int32 = -1

    /// Lets this process change the cursor while another app is frontmost. Idempotent.
    static func enable() {
        guard !enabled else { return }
        let cid = CGSMainConnectionID()
        lastResult = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        enabled = lastResult == 0
    }
}
