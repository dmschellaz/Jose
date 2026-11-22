import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleSession = Self("toggleSession", default: .init(.f, modifiers: [.control, .option]))
    static let markMoment = Self("markMoment", default: .init(.m, modifiers: [.control, .option]))
}
