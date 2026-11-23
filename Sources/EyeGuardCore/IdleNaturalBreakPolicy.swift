import Foundation

/// Persisted configuration for idle pause & natural break credit.
public struct IdleNaturalBreakSettings: Equatable, Codable, Sendable {
    public static let supportedIdleThresholds: [Int] = [60, 120, 300]
    public static let defaultIdlePauseThreshold: TimeInterval = 120
    public static let defaultNaturalBreakMargin: TimeInterval = 20

    public var isEnabled: Bool
    public var idlePauseThreshold: TimeInterval
    public var naturalBreakDuration: TimeInterval

    public init(
        isEnabled: Bool = true,
        idlePauseThreshold: TimeInterval = IdleNaturalBreakSettings.defaultIdlePauseThreshold,
        naturalBreakDuration: TimeInterval? = nil
    ) {
        self.isEnabled = isEnabled
        self.idlePauseThreshold = idlePauseThreshold
        self.naturalBreakDuration = naturalBreakDuration ?? (idlePauseThreshold + Self.defaultNaturalBreakMargin)
    }

    /// Total idle seconds required before away time qualifies as a natural break.
    public var effectiveNaturalBreakDuration: TimeInterval {
        max(max(1, idlePauseThreshold), naturalBreakDuration)
    }
}

/// Current idle-tracking state for Smart Pause.
public enum IdleState: Equatable, Sendable {
    case active
    case idlePaused(idleSeconds: TimeInterval, qualifiedForNaturalBreak: Bool)

    public var isIdlePaused: Bool {
        if case .idlePaused = self {
            return true
        }
        return false
    }

    public var qualifiedForNaturalBreak: Bool {
        if case .idlePaused(_, let qualified) = self {
            return qualified
        }
        return false
    }
}

/// Deterministic state transition produced by evaluating idle time.
public enum IdleTransition: Equatable, Sendable {
    case none
    case enterIdlePause
    case stayIdlePaused(qualifiedForNaturalBreak: Bool)
    case resumePausedCountdown
    case creditNaturalBreakAndReset
}

/// Combined next state and transition returned by `IdleNaturalBreakPolicy`.
public struct IdleEvaluationResult: Equatable, Sendable {
    public let nextState: IdleState
    public let transition: IdleTransition

    public init(nextState: IdleState, transition: IdleTransition) {
        self.nextState = nextState
        self.transition = transition
    }
}

/// Pure, deterministic policy for pausing on user inactivity and crediting qualifying away time
/// as a natural break when the user returns.
public struct IdleNaturalBreakPolicy: Sendable {
    public init() {}

    public func evaluate(
        settings: IdleNaturalBreakSettings,
        currentState: IdleState,
        idleSeconds: TimeInterval,
        isFullscreenOrVideoActive: Bool,
        isOtherSmartPauseActive: Bool
    ) -> IdleEvaluationResult {
        guard settings.isEnabled else {
            if currentState.isIdlePaused {
                return IdleEvaluationResult(nextState: .active, transition: .resumePausedCountdown)
            }
            return IdleEvaluationResult(nextState: .active, transition: .none)
        }

        // Passive watching (fullscreen/video) must never be credited as stepping away
        // or trigger an idle pause.
        if isFullscreenOrVideoActive {
            if currentState.isIdlePaused {
                return IdleEvaluationResult(nextState: .active, transition: .resumePausedCountdown)
            }
            return IdleEvaluationResult(nextState: .active, transition: .none)
        }

        // Higher-priority Smart Pause rules (meetings, screen capture, calendar, deep focus)
        // take precedence over idle tracking.
        if isOtherSmartPauseActive {
            return IdleEvaluationResult(nextState: .active, transition: .none)
        }

        let pauseThreshold = max(1, settings.idlePauseThreshold)
        let breakThreshold = settings.effectiveNaturalBreakDuration
        let sanitizedIdle = idleSeconds.isFinite ? max(0, idleSeconds) : 0
        let qualifiedNow = sanitizedIdle >= breakThreshold

        switch currentState {
        case .active:
            if sanitizedIdle >= pauseThreshold {
                return IdleEvaluationResult(
                    nextState: .idlePaused(
                        idleSeconds: sanitizedIdle,
                        qualifiedForNaturalBreak: qualifiedNow
                    ),
                    transition: .enterIdlePause
                )
            }
            return IdleEvaluationResult(nextState: .active, transition: .none)

        case .idlePaused(_, let wasQualified):
            if sanitizedIdle < pauseThreshold {
                if wasQualified {
                    return IdleEvaluationResult(
                        nextState: .active,
                        transition: .creditNaturalBreakAndReset
                    )
                }
                return IdleEvaluationResult(
                    nextState: .active,
                    transition: .resumePausedCountdown
                )
            }

            let isQualified = wasQualified || qualifiedNow
            return IdleEvaluationResult(
                nextState: .idlePaused(
                    idleSeconds: sanitizedIdle,
                    qualifiedForNaturalBreak: isQualified
                ),
                transition: .stayIdlePaused(qualifiedForNaturalBreak: isQualified)
            )
        }
    }
}
