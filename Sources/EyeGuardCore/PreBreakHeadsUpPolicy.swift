import Foundation

public enum PreBreakLeadTime: Int, CaseIterable, Codable, Equatable, Sendable {
    case off = 0
    case seconds10 = 10
    case seconds20 = 20
    case seconds30 = 30

    public static let defaultLeadTime: PreBreakLeadTime = .seconds20

    public static func validated(_ rawSeconds: Int) -> PreBreakLeadTime {
        PreBreakLeadTime(rawValue: rawSeconds) ?? .defaultLeadTime
    }
}

public enum PreBreakCancellationReason: Equatable, Sendable {
    case snoozed(minutes: Int)
    case skipped
    case disabled
    case systemPause
    case nightLock
}

public enum PreBreakHeadsUpState: Equatable, Sendable {
    case inactive
    case active(remainingSeconds: Int)
    case handoffToBreak
    case cancelled(PreBreakCancellationReason)
}

public struct PreBreakHeadsUpPolicy: Sendable {
    public init() {}

    /// Clamps the configured lead time against the active work/postpone duration so
    /// very short intervals still have at least 1 second before the HUD appears.
    public func effectiveLeadTimeSeconds(
        leadTime: PreBreakLeadTime,
        workDurationSeconds: Int
    ) -> Int {
        guard leadTime != .off, workDurationSeconds > 1 else { return 0 }
        return min(leadTime.rawValue, workDurationSeconds - 1)
    }

    public func state(
        remainingTime: TimeInterval,
        leadTime: PreBreakLeadTime,
        workDurationSeconds: Int,
        isWorkOrPostponeActive: Bool
    ) -> PreBreakHeadsUpState {
        guard isWorkOrPostponeActive else { return .inactive }
        if remainingTime <= 0 {
            return .handoffToBreak
        }

        let effectiveLead = effectiveLeadTimeSeconds(
            leadTime: leadTime,
            workDurationSeconds: workDurationSeconds
        )
        guard effectiveLead > 0 else { return .inactive }

        let remainingSeconds = Int(ceil(remainingTime))
        if remainingSeconds > 0 && remainingSeconds <= effectiveLead {
            return .active(remainingSeconds: remainingSeconds)
        }
        return .inactive
    }

    public func canSnooze(
        minutes: Int,
        totalPostponedTime: TimeInterval,
        maxTotalPostponeTime: TimeInterval
    ) -> Bool {
        guard minutes > 0 else { return false }
        return totalPostponedTime + TimeInterval(minutes * 60) <= maxTotalPostponeTime
    }

    public func snooze(
        minutes: Int,
        totalPostponedTime: TimeInterval,
        maxTotalPostponeTime: TimeInterval
    ) -> PreBreakHeadsUpState? {
        guard canSnooze(
            minutes: minutes,
            totalPostponedTime: totalPostponedTime,
            maxTotalPostponeTime: maxTotalPostponeTime
        ) else {
            return nil
        }
        return .cancelled(.snoozed(minutes: minutes))
    }

    public func skip() -> PreBreakHeadsUpState {
        .cancelled(.skipped)
    }
}
