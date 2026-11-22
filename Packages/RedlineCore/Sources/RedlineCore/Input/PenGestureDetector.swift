public struct ModifierFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let option = ModifierFlags(rawValue: 1 << 0)
    public static let control = ModifierFlags(rawValue: 1 << 1)
    public static let command = ModifierFlags(rawValue: 1 << 2)
    public static let shift = ModifierFlags(rawValue: 1 << 3)
    public static let function = ModifierFlags(rawValue: 1 << 4)
}

/// Turns raw modifier/key events into pen-down / pen-up. The pen is "hold ⌥ alone".
public struct PenGestureDetector: Sendable {
    public enum Output: Equatable, Sendable { case none, penDown, penUp }

    private enum Phase: Equatable, Sendable {
        case idle
        case pending(since: Double)
        case active
        case suppressed   // something else was pressed; wait until every modifier is released
    }

    public let holdDelay: Double
    private var phase: Phase = .idle

    public init(holdDelay: Double = 0.15) { self.holdDelay = holdDelay }

    public var isActive: Bool { phase == .active }
    public var isPending: Bool {
        if case .pending = phase { return true }
        return false
    }

    public mutating func flagsChanged(_ flags: ModifierFlags, at t: Double) -> Output {
        if flags.isEmpty {
            let wasActive = phase == .active
            phase = .idle
            return wasActive ? .penUp : .none
        }
        switch phase {
        case .idle:
            phase = flags == .option ? .pending(since: t) : .suppressed
            return .none
        case .pending:
            if flags != .option { phase = .suppressed }
            return .none
        case .active:
            if flags != .option {
                phase = .suppressed
                return .penUp
            }
            return .none
        case .suppressed:
            return .none
        }
    }

    public mutating func keyDown(at t: Double) -> Output {
        switch phase {
        case .pending:
            phase = .suppressed
            return .none
        case .active:
            phase = .suppressed
            return .penUp
        default:
            return .none
        }
    }

    public mutating func tick(at t: Double) -> Output {
        if case let .pending(since) = phase, t - since >= holdDelay {
            phase = .active
            return .penDown
        }
        return .none
    }
}
