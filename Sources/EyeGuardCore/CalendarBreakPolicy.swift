import Foundation

/// Persisted configuration for Apple Calendar-event-driven breaks.
public struct CalendarBreakSettings: Equatable, Codable, Sendable {
    public static let defaultSuppressionLeadSeconds: TimeInterval = 5 * 60

    public var isEnabled: Bool
    public var selectedCalendarID: String?
    public var selectedCalendarTitle: String?
    public var titleFilter: String
    public var suppressionLeadSeconds: TimeInterval

    public init(
        isEnabled: Bool = false,
        selectedCalendarID: String? = nil,
        selectedCalendarTitle: String? = nil,
        titleFilter: String = "",
        suppressionLeadSeconds: TimeInterval = CalendarBreakSettings.defaultSuppressionLeadSeconds
    ) {
        self.isEnabled = isEnabled
        let trimmedID = selectedCalendarID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedCalendarID = (trimmedID?.isEmpty == false) ? trimmedID : nil
        let trimmedCalTitle = selectedCalendarTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedCalendarTitle = (trimmedCalTitle?.isEmpty == false) ? trimmedCalTitle : nil
        self.titleFilter = titleFilter
        self.suppressionLeadSeconds = max(0, suppressionLeadSeconds)
    }

    public var trimmedTitleFilter: String {
        titleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Concrete occurrence of a calendar-event-driven break.
public struct CalendarBreakOccurrence: Equatable, Sendable {
    public let eventID: String
    public let calendarID: String
    public let title: String
    public let windowStart: Date
    public let windowEnd: Date
    public let occurrenceKey: String

    public init(
        eventID: String,
        calendarID: String,
        title: String,
        windowStart: Date,
        windowEnd: Date
    ) {
        self.eventID = eventID
        self.calendarID = calendarID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.occurrenceKey = "\(eventID)@\(Int(windowStart.timeIntervalSince1970))"
    }

    public init(event: CalendarEventItem) {
        self.init(
            eventID: event.id,
            calendarID: event.calendarID,
            title: event.title,
            windowStart: event.startDate,
            windowEnd: event.endDate
        )
    }

    public var durationSeconds: Int {
        max(0, Int(ceil(windowEnd.timeIntervalSince(windowStart))))
    }

    /// Always computed relative to the original `windowEnd` so postponing retains the event's original end time.
    public func remainingSeconds(at now: Date) -> Int {
        max(0, Int(ceil(windowEnd.timeIntervalSince(now))))
    }
}

public enum CalendarBreakResolutionStatus: String, Equatable, Codable, Sendable {
    case completed
    case skipped
    case creditedAway
    case expired
    case eventRemoved
}

/// Runtime tracking state for calendar-event-driven break occurrences within the app session.
public struct CalendarBreakRuntimeState: Equatable, Sendable {
    public var handledOccurrences: [String: CalendarBreakResolutionStatus]
    public var activeOccurrence: CalendarBreakOccurrence?
    public var postponedOccurrence: CalendarBreakOccurrence?
    public var postponeUntil: Date?
    public var deferredOccurrenceKey: String?
    public var isCalendarMissing: Bool

    public init(
        handledOccurrences: [String: CalendarBreakResolutionStatus] = [:],
        activeOccurrence: CalendarBreakOccurrence? = nil,
        postponedOccurrence: CalendarBreakOccurrence? = nil,
        postponeUntil: Date? = nil,
        deferredOccurrenceKey: String? = nil,
        isCalendarMissing: Bool = false
    ) {
        self.handledOccurrences = handledOccurrences
        self.activeOccurrence = activeOccurrence
        self.postponedOccurrence = postponedOccurrence
        self.postponeUntil = postponeUntil
        self.deferredOccurrenceKey = deferredOccurrenceKey
        self.isCalendarMissing = isCalendarMissing
    }

    public mutating func markHandled(_ occurrence: CalendarBreakOccurrence, status: CalendarBreakResolutionStatus) {
        handledOccurrences[occurrence.occurrenceKey] = status
        if activeOccurrence?.occurrenceKey == occurrence.occurrenceKey {
            activeOccurrence = nil
        }
        if postponedOccurrence?.occurrenceKey == occurrence.occurrenceKey {
            postponedOccurrence = nil
            postponeUntil = nil
        }
        if deferredOccurrenceKey == occurrence.occurrenceKey {
            deferredOccurrenceKey = nil
        }
    }

    public mutating func postpone(_ occurrence: CalendarBreakOccurrence, until: Date) {
        postponedOccurrence = occurrence
        postponeUntil = until
        if activeOccurrence?.occurrenceKey == occurrence.occurrenceKey {
            activeOccurrence = nil
        }
        if deferredOccurrenceKey == occurrence.occurrenceKey {
            deferredOccurrenceKey = nil
        }
    }
}

public enum CalendarBreakDecision: Equatable, Sendable {
    case none
    case trigger(CalendarBreakOccurrence, remainingSeconds: Int)
    case resumePostponed(CalendarBreakOccurrence, remainingSeconds: Int)
    case deferredBySmartPause(CalendarBreakOccurrence, reason: SmartPauseReason?)
    case creditedAway(CalendarBreakOccurrence)
    case expired(CalendarBreakOccurrence)
    case activeEventRemoved(CalendarBreakOccurrence)
}

public struct CalendarBreakEvaluationResult: Equatable, Sendable {
    public let nextState: CalendarBreakRuntimeState
    public let decision: CalendarBreakDecision
    public let shouldSuppressRegularBreak: Bool
    public let suppressedByOccurrence: CalendarBreakOccurrence?
    public let isCalendarMissing: Bool
    public let nextBoundary: Date?

    public init(
        nextState: CalendarBreakRuntimeState,
        decision: CalendarBreakDecision,
        shouldSuppressRegularBreak: Bool,
        suppressedByOccurrence: CalendarBreakOccurrence?,
        isCalendarMissing: Bool,
        nextBoundary: Date?
    ) {
        self.nextState = nextState
        self.decision = decision
        self.shouldSuppressRegularBreak = shouldSuppressRegularBreak
        self.suppressedByOccurrence = suppressedByOccurrence
        self.isCalendarMissing = isCalendarMissing
        self.nextBoundary = nextBoundary
    }
}

/// Pure, deterministic policy resolving Apple Calendar-event-driven breaks,
/// postpone-until-end-time tracking, missing/unsynced calendars, and sleep/wake recovery.
public struct CalendarBreakPolicy: Sendable {
    public static let minimumDeferredResumeSeconds = 10

    public init() {}

    public func creditThreshold(for occurrence: CalendarBreakOccurrence) -> TimeInterval {
        let duration = TimeInterval(occurrence.durationSeconds)
        if duration <= 60 {
            return duration
        }
        return duration * 0.8
    }

    public func isSelectedCalendarMissing(
        settings: CalendarBreakSettings,
        snapshot: CalendarSnapshot
    ) -> Bool {
        guard settings.isEnabled,
              snapshot.permissionState == .authorized,
              let selectedCalendarID = settings.selectedCalendarID,
              !selectedCalendarID.isEmpty else {
            return false
        }
        return !snapshot.availableCalendars.contains(where: { $0.id == selectedCalendarID })
    }

    public func matches(
        event: CalendarEventItem,
        settings: CalendarBreakSettings
    ) -> Bool {
        guard settings.isEnabled,
              let selectedCalendarID = settings.selectedCalendarID,
              !selectedCalendarID.isEmpty else {
            return false
        }
        guard event.calendarID == selectedCalendarID else { return false }
        guard !event.isCanceled else { return false }
        guard !event.isAllDay else { return false }
        guard event.endDate > event.startDate else { return false }

        let filter = settings.trimmedTitleFilter
        if !filter.isEmpty {
            return event.title.localizedCaseInsensitiveContains(filter)
        }
        return true
    }

    public func matchingOccurrences(
        settings: CalendarBreakSettings,
        snapshot: CalendarSnapshot
    ) -> [CalendarBreakOccurrence] {
        guard settings.isEnabled,
              snapshot.permissionState == .authorized,
              !isSelectedCalendarMissing(settings: settings, snapshot: snapshot) else {
            return []
        }

        return snapshot.activeEvents
            .filter { matches(event: $0, settings: settings) }
            .map(CalendarBreakOccurrence.init(event:))
            .sorted { lhs, rhs in
                if lhs.windowStart != rhs.windowStart {
                    return lhs.windowStart < rhs.windowStart
                }
                if lhs.windowEnd != rhs.windowEnd {
                    return lhs.windowEnd < rhs.windowEnd
                }
                return lhs.occurrenceKey < rhs.occurrenceKey
            }
    }

    public func nextBoundary(
        settings: CalendarBreakSettings,
        snapshot: CalendarSnapshot,
        state: CalendarBreakRuntimeState = CalendarBreakRuntimeState(),
        now: Date
    ) -> Date? {
        guard settings.isEnabled,
              snapshot.permissionState == .authorized,
              !isSelectedCalendarMissing(settings: settings, snapshot: snapshot) else {
            return nil
        }

        var candidates: [Date] = []

        if let postponed = state.postponedOccurrence,
           state.handledOccurrences[postponed.occurrenceKey] == nil {
            if let postponeUntil = state.postponeUntil, postponeUntil > now {
                candidates.append(min(postponeUntil, postponed.windowEnd))
            } else if postponed.windowEnd > now {
                candidates.append(postponed.windowEnd)
            }
        }

        for occurrence in matchingOccurrences(settings: settings, snapshot: snapshot) {
            guard state.handledOccurrences[occurrence.occurrenceKey] == nil else { continue }
            if occurrence.windowStart > now {
                candidates.append(occurrence.windowStart)
            } else if occurrence.windowEnd > now {
                candidates.append(occurrence.windowEnd)
            }
        }

        return candidates.min()
    }

    public func evaluate(
        settings: CalendarBreakSettings,
        snapshot: CalendarSnapshot,
        state: CalendarBreakRuntimeState,
        now: Date,
        smartPauseEvaluation: SmartPauseEvaluation = .activeNone,
        awayInterval: DateInterval? = nil,
        isNightLocked: Bool = false,
        isTemporarilyDisabled: Bool = false
    ) -> CalendarBreakEvaluationResult {
        var nextState = state
        let isMissing = isSelectedCalendarMissing(settings: settings, snapshot: snapshot)
        nextState.isCalendarMissing = isMissing

        let candidates = matchingOccurrences(settings: settings, snapshot: snapshot)
        let candidateKeys = Set(candidates.map(\.occurrenceKey))

        var decision: CalendarBreakDecision = .none
        var shouldSuppress = false
        var suppressedBy: CalendarBreakOccurrence?

        // If an active calendar break's event was removed/rescheduled/unmatched during sync before its natural end,
        // cancel it cleanly so the user isn't stuck in a break for a deleted event.
        if let active = nextState.activeOccurrence {
            if !candidateKeys.contains(active.occurrenceKey) && now < active.windowEnd {
                nextState.markHandled(active, status: .eventRemoved)
                decision = .activeEventRemoved(active)
            }
        }

        // Handle any postponed calendar break occurrence, always preserving its original `windowEnd`.
        if let postponed = nextState.postponedOccurrence {
            if !candidateKeys.contains(postponed.occurrenceKey) {
                nextState.markHandled(postponed, status: .eventRemoved)
                if case .none = decision {
                    decision = .activeEventRemoved(postponed)
                }
            } else if now >= postponed.windowEnd {
                nextState.markHandled(postponed, status: .expired)
                if case .none = decision {
                    decision = .expired(postponed)
                }
            } else if let awayInterval,
                      let overlap = awayInterval.intersection(with: DateInterval(start: postponed.windowStart, end: postponed.windowEnd))?.duration,
                      overlap > 0,
                      overlap >= creditThreshold(for: postponed) {
                nextState.markHandled(postponed, status: .creditedAway)
                if case .none = decision {
                    decision = .creditedAway(postponed)
                }
            } else if let postponeUntil = nextState.postponeUntil, now >= postponeUntil {
                if !isNightLocked && !isTemporarilyDisabled {
                    shouldSuppress = true
                    suppressedBy = suppressedBy ?? postponed
                    if isEffectiveSmartPause(smartPauseEvaluation, for: postponed) {
                        nextState.deferredOccurrenceKey = postponed.occurrenceKey
                        if case .none = decision {
                            decision = .deferredBySmartPause(postponed, reason: smartPauseEvaluation.reason)
                        }
                    } else {
                        let remaining = postponed.remainingSeconds(at: now)
                        if remaining <= 0 {
                            nextState.markHandled(postponed, status: .expired)
                            if case .none = decision {
                                decision = .expired(postponed)
                            }
                        } else {
                            nextState.postponedOccurrence = nil
                            nextState.postponeUntil = nil
                            nextState.deferredOccurrenceKey = nil
                            if case .none = decision {
                                decision = .resumePostponed(postponed, remainingSeconds: remaining)
                            }
                        }
                    }
                }
            } else if !isNightLocked && !isTemporarilyDisabled {
                shouldSuppress = true
                suppressedBy = suppressedBy ?? postponed
            }
        }

        if isNightLocked || isTemporarilyDisabled {
            return CalendarBreakEvaluationResult(
                nextState: nextState,
                decision: decision,
                shouldSuppressRegularBreak: false,
                suppressedByOccurrence: nil,
                isCalendarMissing: isMissing,
                nextBoundary: nextBoundary(settings: settings, snapshot: snapshot, state: nextState, now: now)
            )
        }

        for occurrence in candidates {
            if nextState.handledOccurrences[occurrence.occurrenceKey] != nil {
                continue
            }

            if nextState.activeOccurrence?.occurrenceKey == occurrence.occurrenceKey {
                shouldSuppress = true
                suppressedBy = suppressedBy ?? occurrence
                continue
            }

            if nextState.postponedOccurrence?.occurrenceKey == occurrence.occurrenceKey {
                continue
            }

            // 1. Credit away time (sleep/screen lock/idle) overlapping the event window.
            if let awayInterval, occurrence.windowStart <= now {
                let windowInterval = DateInterval(start: occurrence.windowStart, end: occurrence.windowEnd)
                if let overlap = awayInterval.intersection(with: windowInterval)?.duration, overlap > 0 {
                    let threshold = creditThreshold(for: occurrence)
                    if overlap >= threshold || now >= occurrence.windowEnd {
                        nextState.markHandled(occurrence, status: .creditedAway)
                        if case .none = decision {
                            decision = .creditedAway(occurrence)
                        }
                        continue
                    }
                }
            }

            // 2. Expire events whose window has already ended.
            if now >= occurrence.windowEnd {
                nextState.markHandled(occurrence, status: .expired)
                if case .none = decision {
                    decision = .expired(occurrence)
                }
                continue
            }

            // 3. Currently inside the event window [windowStart, windowEnd).
            if now >= occurrence.windowStart {
                shouldSuppress = true
                suppressedBy = suppressedBy ?? occurrence

                if isEffectiveSmartPause(smartPauseEvaluation, for: occurrence) {
                    nextState.deferredOccurrenceKey = occurrence.occurrenceKey
                    if case .none = decision {
                        decision = .deferredBySmartPause(occurrence, reason: smartPauseEvaluation.reason)
                    }
                    continue
                }

                let remaining = occurrence.remainingSeconds(at: now)
                let wasDeferred = nextState.deferredOccurrenceKey == occurrence.occurrenceKey
                if wasDeferred && remaining < Self.minimumDeferredResumeSeconds {
                    nextState.markHandled(occurrence, status: .expired)
                    if case .none = decision {
                        decision = .expired(occurrence)
                    }
                    continue
                }

                nextState.deferredOccurrenceKey = nil
                if case .none = decision {
                    decision = .trigger(occurrence, remainingSeconds: max(1, remaining))
                }
                continue
            }

            // 4. Upcoming calendar break: suppress regular breaks within the lead window.
            let leadStart = occurrence.windowStart.addingTimeInterval(-max(0, settings.suppressionLeadSeconds))
            if now >= leadStart {
                shouldSuppress = true
                suppressedBy = suppressedBy ?? occurrence
            }
        }

        return CalendarBreakEvaluationResult(
            nextState: nextState,
            decision: decision,
            shouldSuppressRegularBreak: shouldSuppress,
            suppressedByOccurrence: suppressedBy,
            isCalendarMissing: isMissing,
            nextBoundary: nextBoundary(settings: settings, snapshot: snapshot, state: nextState, now: now)
        )
    }

    private func isEffectiveSmartPause(
        _ evaluation: SmartPauseEvaluation,
        for occurrence: CalendarBreakOccurrence
    ) -> Bool {
        guard evaluation.isPaused else { return false }
        // Never let a calendar break event self-block via CalendarPausePolicy.
        if case .calendarEvent(let pauseTitle) = evaluation.reason {
            let normalizedPauseTitle = (pauseTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedOccurrenceTitle = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedPauseTitle == normalizedOccurrenceTitle {
                return false
            }
        }
        return true
    }
}
