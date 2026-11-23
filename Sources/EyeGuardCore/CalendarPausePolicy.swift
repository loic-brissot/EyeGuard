import Foundation

/// Authorization state for Apple Calendar (EventKit) access.
public enum CalendarPermissionState: String, Equatable, Codable, Sendable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// Action taken when a break falls during a qualifying busy calendar event.
public enum CalendarBreakAction: String, Equatable, Codable, Sendable, CaseIterable {
    /// Pause/defer breaks until the event ends, then resume the previous timer state.
    case postpone
    /// Skip breaks during the event and start a fresh work session when the event ends.
    case skip
}

/// Availability status of a calendar event.
public enum CalendarAvailability: String, Equatable, Codable, Sendable {
    case busy
    case free
    case tentative
    case unavailable
    case notSupported
}

/// Lightweight, platform-independent descriptor for an Apple Calendar source/calendar.
public struct CalendarDescriptor: Equatable, Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let sourceTitle: String

    public init(id: String, title: String, sourceTitle: String) {
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lightweight, platform-independent representation of a calendar event.
public struct CalendarEventItem: Equatable, Identifiable, Sendable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let isAllDay: Bool
    public let availability: CalendarAvailability
    public let isCanceled: Bool

    public init(
        id: String,
        calendarID: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        availability: CalendarAvailability = .busy,
        isCanceled: Bool = false
    ) {
        self.id = id
        self.calendarID = calendarID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.availability = availability
        self.isCanceled = isCanceled
    }
}

/// Persisted configuration for Apple Calendar Smart Pause.
///
/// - Note: `isEnabled` defaults to `false` so EyeGuard does not prompt for Calendar access on launch.
///   When `selectedCalendarIDs` is empty, all available calendars are monitored.
public struct CalendarPauseSettings: Equatable, Codable, Sendable {
    public var isEnabled: Bool
    public var selectedCalendarIDs: Set<String>
    public var breakAction: CalendarBreakAction

    public init(
        isEnabled: Bool = false,
        selectedCalendarIDs: Set<String> = [],
        breakAction: CalendarBreakAction = .postpone
    ) {
        self.isEnabled = isEnabled
        self.selectedCalendarIDs = selectedCalendarIDs
        self.breakAction = breakAction
    }
}

/// Platform-independent snapshot of Calendar permission, calendars, and nearby events.
public struct CalendarSnapshot: Equatable, Sendable {
    public let permissionState: CalendarPermissionState
    public let activeEvents: [CalendarEventItem]
    public let availableCalendars: [CalendarDescriptor]

    public init(
        permissionState: CalendarPermissionState = .notDetermined,
        activeEvents: [CalendarEventItem] = [],
        availableCalendars: [CalendarDescriptor] = []
    ) {
        self.permissionState = permissionState
        self.activeEvents = activeEvents
        self.availableCalendars = availableCalendars
    }

    public static let empty = CalendarSnapshot(
        permissionState: .notDetermined,
        activeEvents: [],
        availableCalendars: []
    )
}

/// Pure, deterministic policy for pausing breaks during active non-all-day busy Apple Calendar events.
///
/// Filtering rules:
/// - Requires `settings.isEnabled == true` and `snapshot.permissionState == .authorized`.
/// - Filters out all-day events (`isAllDay == true`), canceled events (`isCanceled == true`),
///   non-busy events (`availability != .busy`), events outside `[startDate, endDate)` at `now`,
///   and events whose `calendarID` is not in `settings.selectedCalendarIDs` (when non-empty).
/// - For overlapping qualifying events, deterministically selects the latest-ending event
///   (breaking ties by earliest `startDate`, then `id`) and stays paused until all overlapping
///   qualifying events have ended.
public struct CalendarPausePolicy: Sendable {
    public init() {}

    public func qualifyingEvents(
        settings: CalendarPauseSettings,
        snapshot: CalendarSnapshot,
        now: Date = Date(),
        excludedBreakSettings: CalendarBreakSettings? = nil
    ) -> [CalendarEventItem] {
        guard settings.isEnabled, snapshot.permissionState == .authorized else {
            return []
        }

        let breakPolicy = CalendarBreakPolicy()
        return snapshot.activeEvents.filter { event in
            if let excludedBreakSettings,
               excludedBreakSettings.isEnabled,
               breakPolicy.matches(event: event, settings: excludedBreakSettings) {
                return false
            }
            guard !event.isAllDay else { return false }
            guard !event.isCanceled else { return false }
            guard event.availability == .busy else { return false }
            guard event.startDate <= now && now < event.endDate else { return false }
            if !settings.selectedCalendarIDs.isEmpty {
                return settings.selectedCalendarIDs.contains(event.calendarID)
            }
            return true
        }
    }

    public func evaluate(
        settings: CalendarPauseSettings,
        snapshot: CalendarSnapshot,
        now: Date = Date(),
        excludedBreakSettings: CalendarBreakSettings? = nil
    ) -> SmartPauseEvaluation {
        let active = qualifyingEvents(
            settings: settings,
            snapshot: snapshot,
            now: now,
            excludedBreakSettings: excludedBreakSettings
        )
        guard let selectedEvent = active.sorted(by: { lhs, rhs in
            if lhs.endDate != rhs.endDate {
                return lhs.endDate > rhs.endDate
            }
            if lhs.startDate != rhs.startDate {
                return lhs.startDate < rhs.startDate
            }
            return lhs.id < rhs.id
        }).first else {
            return .activeNone
        }

        let trimmedTitle = selectedEvent.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedTitle.isEmpty ? nil : trimmedTitle

        return SmartPauseEvaluation(
            isPaused: true,
            reason: .calendarEvent(title: title),
            matchedAppName: title,
            matchedBundleID: nil
        )
    }
}
