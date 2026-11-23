import Foundation

public struct BreakSkipSettings: Equatable, Sendable {
    public static let supportedDelaySeconds = [0, 3, 5]
    public static let defaultDelaySeconds = 3

    public var isStrictMode: Bool
    public var skipDelaySeconds: Int

    public init(
        isStrictMode: Bool = false,
        skipDelaySeconds: Int = BreakSkipSettings.defaultDelaySeconds
    ) {
        self.isStrictMode = isStrictMode
        self.skipDelaySeconds = max(0, skipDelaySeconds)
    }

    public var allowsSkip: Bool {
        !isStrictMode
    }
}

public enum BreakSkipState: Equatable, Sendable {
    case hidden
    case locked(remainingSeconds: Int)
    case unlocked
}

public struct BreakSkipPolicy: Sendable {
    public init() {}

    public func state(
        settings: BreakSkipSettings,
        breakStartTime: Date?,
        now: Date
    ) -> BreakSkipState {
        guard settings.allowsSkip else {
            return .hidden
        }
        guard settings.skipDelaySeconds > 0 else {
            return .unlocked
        }
        guard let breakStartTime else {
            return .locked(remainingSeconds: settings.skipDelaySeconds)
        }

        let elapsed = max(0, now.timeIntervalSince(breakStartTime))
        let remaining = Int(ceil(TimeInterval(settings.skipDelaySeconds) - elapsed))
        if remaining > 0 {
            return .locked(remainingSeconds: remaining)
        }
        return .unlocked
    }

    public func isSkipUnlocked(
        settings: BreakSkipSettings,
        breakStartTime: Date?,
        now: Date
    ) -> Bool {
        state(settings: settings, breakStartTime: breakStartTime, now: now) == .unlocked
    }

    public func remainingDelaySeconds(
        settings: BreakSkipSettings,
        breakStartTime: Date?,
        now: Date
    ) -> Int {
        switch state(settings: settings, breakStartTime: breakStartTime, now: now) {
        case .locked(let remaining):
            return remaining
        case .hidden, .unlocked:
            return 0
        }
    }
}
