import Foundation

/// A user-configured fixed-time planned break (e.g. Lunch, Afternoon Walk, End-of-Day Pause).
public struct PlannedBreakSchedule: Identifiable, Equatable, Codable, Sendable {
    public static let allWeekdays: Set<Int> = Set(1...7)
    public static let workWeekdays: Set<Int> = Set(2...6)
    public static let weekendWeekdays: Set<Int> = [1, 7]
    public static let minimumDurationSeconds = 10
    public static let maximumDurationSeconds = 180 * 60

    public let id: UUID
    public var name: String
    public var hour: Int
    public var minute: Int
    public var durationSeconds: Int
    public var weekdays: Set<Int>
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        hour: Int,
        minute: Int,
        durationSeconds: Int,
        weekdays: Set<Int> = PlannedBreakSchedule.allWeekdays,
        isEnabled: Bool = true
    ) {
        self.id = id
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = trimmed
        self.hour = min(23, max(0, hour))
        self.minute = min(59, max(0, minute))
        self.durationSeconds = min(Self.maximumDurationSeconds, max(Self.minimumDurationSeconds, durationSeconds))
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.isEnabled = isEnabled
    }

    public init(
        id: UUID = UUID(),
        name: String,
        hour: Int,
        minute: Int,
        durationMinutes: Int,
        weekdays: Set<Int> = PlannedBreakSchedule.allWeekdays,
        isEnabled: Bool = true
    ) {
        self.init(
            id: id,
            name: name,
            hour: hour,
            minute: minute,
            durationSeconds: max(1, durationMinutes) * 60,
            weekdays: weekdays,
            isEnabled: isEnabled
        )
    }

    public var durationMinutes: Int {
        max(1, Int(round(Double(durationSeconds) / 60.0)))
    }

    public var formattedStartTime: String {
        String(format: "%02d:%02d", hour, minute)
    }
}

/// Persisted configuration for fixed-time planned breaks.
public struct PlannedBreakSettings: Equatable, Codable, Sendable {
    public static let defaultSuppressionLeadSeconds: TimeInterval = 5 * 60

    public var schedules: [PlannedBreakSchedule]
    public var suppressionLeadSeconds: TimeInterval

    public init(
        schedules: [PlannedBreakSchedule] = [],
        suppressionLeadSeconds: TimeInterval = PlannedBreakSettings.defaultSuppressionLeadSeconds
    ) {
        self.schedules = schedules
        self.suppressionLeadSeconds = max(0, suppressionLeadSeconds)
    }

    public func adding(_ schedule: PlannedBreakSchedule) -> PlannedBreakSettings {
        var copy = self
        copy.add(schedule)
        return copy
    }

    public mutating func add(_ schedule: PlannedBreakSchedule) {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
    }

    public func updating(_ schedule: PlannedBreakSchedule) -> PlannedBreakSettings {
        var copy = self
        copy.update(schedule)
        return copy
    }

    public mutating func update(_ schedule: PlannedBreakSchedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
    }

    public func removing(id: UUID) -> PlannedBreakSettings {
        var copy = self
        copy.remove(id: id)
        return copy
    }

    public mutating func remove(id: UUID) {
        schedules.removeAll { $0.id == id }
    }

    public func toggling(id: UUID) -> PlannedBreakSettings {
        var copy = self
        copy.toggle(id: id)
        return copy
    }

    public mutating func toggle(id: UUID) {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].isEnabled.toggle()
    }
}

/// Concrete occurrence of a planned break on a specific date.
public struct PlannedBreakOccurrence: Equatable, Sendable {
    public let schedule: PlannedBreakSchedule
    public let occurrenceKey: String
    public let windowStart: Date
    public let windowEnd: Date

    public init(schedule: PlannedBreakSchedule, windowStart: Date) {
        self.schedule = schedule
        self.windowStart = windowStart
        self.windowEnd = windowStart.addingTimeInterval(TimeInterval(schedule.durationSeconds))
        self.occurrenceKey = "\(schedule.id.uuidString)@\(Int(windowStart.timeIntervalSince1970))"
    }

    public func remainingSeconds(at now: Date) -> Int {
        max(0, Int(ceil(windowEnd.timeIntervalSince(now))))
    }
}

public enum PlannedBreakResolutionStatus: String, Equatable, Codable, Sendable {
    case completed
    case creditedAway
    case expired
}

/// Runtime tracking state for planned break occurrences within the app session.
public struct PlannedBreakRuntimeState: Equatable, Sendable {
    public var handledOccurrences: [String: PlannedBreakResolutionStatus]
    public var deferredOccurrenceKey: String?
    public var activeOccurrence: PlannedBreakOccurrence?

    public init(
        handledOccurrences: [String: PlannedBreakResolutionStatus] = [:],
        deferredOccurrenceKey: String? = nil,
        activeOccurrence: PlannedBreakOccurrence? = nil
    ) {
        self.handledOccurrences = handledOccurrences
        self.deferredOccurrenceKey = deferredOccurrenceKey
        self.activeOccurrence = activeOccurrence
    }

    public mutating func markHandled(_ occurrence: PlannedBreakOccurrence, status: PlannedBreakResolutionStatus) {
        handledOccurrences[occurrence.occurrenceKey] = status
        if deferredOccurrenceKey == occurrence.occurrenceKey {
            deferredOccurrenceKey = nil
        }
        if activeOccurrence?.occurrenceKey == occurrence.occurrenceKey {
            activeOccurrence = nil
        }
    }
}

public enum PlannedBreakDecision: Equatable, Sendable {
    case none
    case trigger(PlannedBreakOccurrence, remainingSeconds: Int)
    case deferredBySmartPause(PlannedBreakOccurrence, reason: SmartPauseReason?)
    case creditedAway(PlannedBreakOccurrence)
    case expired(PlannedBreakOccurrence)
}

public struct PlannedBreakEvaluationResult: Equatable, Sendable {
    public let nextState: PlannedBreakRuntimeState
    public let decision: PlannedBreakDecision
    public let shouldSuppressRegularBreak: Bool
    public let suppressedByOccurrence: PlannedBreakOccurrence?
    public let nextBoundary: Date?

    public init(
        nextState: PlannedBreakRuntimeState,
        decision: PlannedBreakDecision,
        shouldSuppressRegularBreak: Bool,
        suppressedByOccurrence: PlannedBreakOccurrence?,
        nextBoundary: Date?
    ) {
        self.nextState = nextState
        self.decision = decision
        self.shouldSuppressRegularBreak = shouldSuppressRegularBreak
        self.suppressedByOccurrence = suppressedByOccurrence
        self.nextBoundary = nextBoundary
    }
}

/// Pure, deterministic policy resolving fixed-time planned breaks, regular interval suppression,
/// Smart Pause deferral, and away-time crediting.
public struct PlannedBreakPolicy: Sendable {
    public init() {}

    public func creditThreshold(for schedule: PlannedBreakSchedule) -> TimeInterval {
        let duration = TimeInterval(schedule.durationSeconds)
        if duration <= 60 {
            return duration
        }
        return duration * 0.8
    }

    public func occurrences(
        in settings: PlannedBreakSettings,
        around date: Date,
        calendar: Calendar = .current
    ) -> [PlannedBreakOccurrence] {
        let startOfToday = calendar.startOfDay(for: date)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else {
            return occurrences(in: settings, onDayStartingAt: startOfToday, calendar: calendar)
        }
        let yesterdayOccurrences = occurrences(in: settings, onDayStartingAt: startOfYesterday, calendar: calendar)
            .filter { $0.windowEnd > startOfToday }
        let todayOccurrences = occurrences(in: settings, onDayStartingAt: startOfToday, calendar: calendar)
        return (yesterdayOccurrences + todayOccurrences).sorted {
            if $0.windowStart != $1.windowStart {
                return $0.windowStart < $1.windowStart
            }
            return $0.schedule.id.uuidString < $1.schedule.id.uuidString
        }
    }

    private func occurrences(
        in settings: PlannedBreakSettings,
        onDayStartingAt dayStart: Date,
        calendar: Calendar
    ) -> [PlannedBreakOccurrence] {
        let weekday = calendar.component(.weekday, from: dayStart)
        return settings.schedules.compactMap { schedule in
            guard schedule.isEnabled, schedule.weekdays.contains(weekday) else {
                return nil
            }
            var components = calendar.dateComponents([.year, .month, .day], from: dayStart)
            components.hour = schedule.hour
            components.minute = schedule.minute
            components.second = 0
            guard let windowStart = calendar.date(from: components) else {
                return nil
            }
            return PlannedBreakOccurrence(schedule: schedule, windowStart: windowStart)
        }
    }

    public func nextBoundary(
        settings: PlannedBreakSettings,
        state: PlannedBreakRuntimeState = PlannedBreakRuntimeState(),
        now: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard settings.schedules.contains(where: { $0.isEnabled && !$0.weekdays.isEmpty }) else {
            return nil
        }

        var candidates: [Date] = []

        // Check active/yesterday/today windows first.
        for occurrence in occurrences(in: settings, around: now, calendar: calendar) {
            guard state.handledOccurrences[occurrence.occurrenceKey] == nil else { continue }
            if occurrence.windowStart > now {
                candidates.append(occurrence.windowStart)
            } else if occurrence.windowEnd > now {
                candidates.append(occurrence.windowEnd)
            }
        }

        // Look ahead up to 7 days for the next scheduled start.
        let startOfToday = calendar.startOfDay(for: now)
        for dayOffset in 1...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            for occurrence in occurrences(in: settings, onDayStartingAt: day, calendar: calendar) {
                guard state.handledOccurrences[occurrence.occurrenceKey] == nil else { continue }
                if occurrence.windowStart > now {
                    candidates.append(occurrence.windowStart)
                }
            }
        }

        return candidates.min()
    }

    public func evaluate(
        settings: PlannedBreakSettings,
        state: PlannedBreakRuntimeState,
        now: Date,
        calendar: Calendar = .current,
        smartPauseEvaluation: SmartPauseEvaluation = .activeNone,
        awayInterval: DateInterval? = nil,
        isNightLocked: Bool = false,
        isTemporarilyDisabled: Bool = false
    ) -> PlannedBreakEvaluationResult {
        var nextState = state
        let candidates = occurrences(in: settings, around: now, calendar: calendar)

        if isNightLocked || isTemporarilyDisabled {
            return PlannedBreakEvaluationResult(
                nextState: nextState,
                decision: .none,
                shouldSuppressRegularBreak: false,
                suppressedByOccurrence: nil,
                nextBoundary: nextBoundary(settings: settings, state: nextState, now: now, calendar: calendar)
            )
        }

        var decision: PlannedBreakDecision = .none
        var shouldSuppress = false
        var suppressedBy: PlannedBreakOccurrence?

        for occurrence in candidates {
            if nextState.handledOccurrences[occurrence.occurrenceKey] != nil {
                continue
            }

            // If this occurrence is already actively being presented, suppress regular breaks
            // and do not re-trigger.
            if nextState.activeOccurrence?.occurrenceKey == occurrence.occurrenceKey {
                shouldSuppress = true
                suppressedBy = suppressedBy ?? occurrence
                continue
            }

            // 1. Credit away time (idle/sleep/screen lock) overlapping the planned break window.
            if let awayInterval, occurrence.windowStart <= now {
                let windowInterval = DateInterval(start: occurrence.windowStart, end: occurrence.windowEnd)
                if let overlap = awayInterval.intersection(with: windowInterval)?.duration, overlap > 0 {
                    let threshold = creditThreshold(for: occurrence.schedule)
                    if overlap >= threshold || now >= occurrence.windowEnd {
                        nextState.markHandled(occurrence, status: .creditedAway)
                        if case .none = decision {
                            decision = .creditedAway(occurrence)
                        }
                        continue
                    }
                }
            }

            // 2. If the window has completely passed, expire it cleanly.
            if now >= occurrence.windowEnd {
                nextState.markHandled(occurrence, status: .expired)
                if case .none = decision {
                    decision = .expired(occurrence)
                }
                continue
            }

            // 3. Currently inside the planned break window [windowStart, windowEnd).
            if now >= occurrence.windowStart {
                shouldSuppress = true
                suppressedBy = suppressedBy ?? occurrence

                if smartPauseEvaluation.isPaused {
                    nextState.deferredOccurrenceKey = occurrence.occurrenceKey
                    if case .none = decision {
                        decision = .deferredBySmartPause(occurrence, reason: smartPauseEvaluation.reason)
                    }
                    continue
                }

                let remaining = occurrence.remainingSeconds(at: now)
                let wasDeferred = nextState.deferredOccurrenceKey == occurrence.occurrenceKey
                if wasDeferred && remaining < PlannedBreakSchedule.minimumDurationSeconds {
                    nextState.markHandled(occurrence, status: .expired)
                    if case .none = decision {
                        decision = .expired(occurrence)
                    }
                    continue
                }

                nextState.deferredOccurrenceKey = nil
                let effectiveDuration = min(occurrence.schedule.durationSeconds, max(1, remaining))
                if case .none = decision {
                    decision = .trigger(occurrence, remainingSeconds: effectiveDuration)
                }
                continue
            }

            // 4. Upcoming planned break: check suppression lead window [windowStart - lead, windowStart).
            let leadStart = occurrence.windowStart.addingTimeInterval(-max(0, settings.suppressionLeadSeconds))
            if now >= leadStart {
                shouldSuppress = true
                suppressedBy = suppressedBy ?? occurrence
            }
        }

        return PlannedBreakEvaluationResult(
            nextState: nextState,
            decision: decision,
            shouldSuppressRegularBreak: shouldSuppress,
            suppressedByOccurrence: suppressedBy,
            nextBoundary: nextBoundary(settings: settings, state: nextState, now: now, calendar: calendar)
        )
    }
}
