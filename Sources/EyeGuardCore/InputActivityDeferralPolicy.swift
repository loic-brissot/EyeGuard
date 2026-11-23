import Foundation

/// Injectable snapshot of recent keyboard and mouse-drag activity.
public struct InputActivityState: Equatable, Sendable {
    public let secondsSinceLastKeystroke: TimeInterval?
    public let isMouseButtonDown: Bool
    public let secondsSinceLastDragRelease: TimeInterval?

    public init(
        secondsSinceLastKeystroke: TimeInterval? = nil,
        isMouseButtonDown: Bool = false,
        secondsSinceLastDragRelease: TimeInterval? = nil
    ) {
        self.secondsSinceLastKeystroke = secondsSinceLastKeystroke
        self.isMouseButtonDown = isMouseButtonDown
        self.secondsSinceLastDragRelease = secondsSinceLastDragRelease
    }

    public static let idle = InputActivityState()
}

/// Persisted configuration for deferring due breaks during active typing or mouse dragging.
public struct InputDeferralSettings: Equatable, Codable, Sendable {
    public static let defaultIdleGraceWindow: TimeInterval = 3.0
    public static let defaultMaxWaitThreshold: TimeInterval = 60.0
    public static let supportedMaxWaitThresholds: [Int] = [30, 60, 120]

    public var isEnabled: Bool
    public var idleGraceWindow: TimeInterval
    public var maxWaitThreshold: TimeInterval

    public init(
        isEnabled: Bool = true,
        idleGraceWindow: TimeInterval = defaultIdleGraceWindow,
        maxWaitThreshold: TimeInterval = defaultMaxWaitThreshold
    ) {
        self.isEnabled = isEnabled
        self.idleGraceWindow = max(0, idleGraceWindow)
        self.maxWaitThreshold = max(0, maxWaitThreshold)
    }

    public static func validatedMaxWaitSeconds(_ seconds: Int) -> Int {
        supportedMaxWaitThresholds.contains(seconds) ? seconds : Int(defaultMaxWaitThreshold)
    }
}

public enum InputDeferralReason: Equatable, Sendable {
    case typing
    case dragging
    case typingAndDragging
}

public enum InputDeferralDecision: Equatable, Sendable {
    case triggerNow
    case deferBreak(reason: InputDeferralReason, recheckAfter: TimeInterval)
}

/// Pure, deterministic policy for deferring a due break until typing/dragging settles
/// or a bounded maximum wait threshold is reached.
public struct InputActivityDeferralPolicy: Sendable {
    public static let defaultRecheckInterval: TimeInterval = 0.5
    public static let minimumRecheckInterval: TimeInterval = 0.1

    public init() {}

    public func evaluate(
        settings: InputDeferralSettings,
        activity: InputActivityState,
        waitDuration: TimeInterval
    ) -> InputDeferralDecision {
        guard settings.isEnabled else {
            return .triggerNow
        }

        let clampedWait = max(0, waitDuration)
        if clampedWait >= settings.maxWaitThreshold {
            return .triggerNow
        }

        let isTypingActive: Bool
        let typingRemaining: TimeInterval
        if let keyAge = activity.secondsSinceLastKeystroke,
           keyAge >= 0,
           keyAge < settings.idleGraceWindow {
            isTypingActive = true
            typingRemaining = settings.idleGraceWindow - keyAge
        } else {
            isTypingActive = false
            typingRemaining = 0
        }

        let isDraggingActive: Bool
        let dragRemaining: TimeInterval
        if activity.isMouseButtonDown {
            isDraggingActive = true
            dragRemaining = settings.idleGraceWindow
        } else if let releaseAge = activity.secondsSinceLastDragRelease,
                  releaseAge >= 0,
                  releaseAge < settings.idleGraceWindow {
            isDraggingActive = true
            dragRemaining = settings.idleGraceWindow - releaseAge
        } else {
            isDraggingActive = false
            dragRemaining = 0
        }

        guard isTypingActive || isDraggingActive else {
            return .triggerNow
        }

        let reason: InputDeferralReason
        switch (isTypingActive, isDraggingActive) {
        case (true, true):
            reason = .typingAndDragging
        case (true, false):
            reason = .typing
        case (false, true):
            reason = .dragging
        case (false, false):
            return .triggerNow
        }

        let maxRemainingWait = max(0, settings.maxWaitThreshold - clampedWait)
        let neededGrace = max(typingRemaining, dragRemaining)
        let recheck = min(
            maxRemainingWait,
            max(Self.minimumRecheckInterval, min(Self.defaultRecheckInterval, neededGrace))
        )

        return .deferBreak(reason: reason, recheckAfter: recheck)
    }
}
