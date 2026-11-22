import KeyboardShortcuts

enum Hotkeys {
    /// KeyboardShortcuts saves the default the first time it runs, so changing the default in code
    /// doesn't reach existing installs. Move anyone still on an old ⌃⌥ default (⌃⌥F is Magnet's
    /// "Center Third") to the current default; a shortcut the user picked themselves is kept.
    @MainActor static func migrateOldDefaults() {
        let old: [(KeyboardShortcuts.Name, KeyboardShortcuts.Shortcut)] = [
            (.toggleSession, .init(.f, modifiers: [.control, .option])),
            (.markMoment, .init(.m, modifiers: [.control, .option])),
        ]
        for (name, shortcut) in old where KeyboardShortcuts.getShortcut(for: name) == shortcut {
            KeyboardShortcuts.reset(name)
        }
    }
}

extension KeyboardShortcuts.Name {
    static let toggleSession = Self("toggleSession", default: .init(.f, modifiers: [.control, .option, .shift]))
    static let markMoment = Self("markMoment", default: .init(.m, modifiers: [.control, .option, .shift]))
}
