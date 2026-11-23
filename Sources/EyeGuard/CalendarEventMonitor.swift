import Cocoa
import EventKit
import EyeGuardCore

protocol CalendarSignalProviding {
    func currentSnapshot(now: Date) -> CalendarSnapshot
    func requestAccess(completion: @escaping (CalendarPermissionState) -> Void)
}

struct SystemCalendarSignalProvider: CalendarSignalProviding {
    private let eventStore: EKEventStore

    init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    func currentSnapshot(now: Date = Date()) -> CalendarSnapshot {
        let permissionState = Self.currentPermissionState()
        guard permissionState == .authorized else {
            return CalendarSnapshot(
                permissionState: permissionState,
                activeEvents: [],
                availableCalendars: []
            )
        }

        let ekCalendars = eventStore.calendars(for: .event)
        let calendars = ekCalendars.map { calendar in
            CalendarDescriptor(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceTitle: calendar.source?.title ?? ""
            )
        }.sorted { lhs, rhs in
            if lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle) != .orderedSame {
                return lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle) == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        let windowStart = now.addingTimeInterval(-12 * 3600)
        let windowEnd = now.addingTimeInterval(12 * 3600)
        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: nil)
        let ekEvents = eventStore.events(matching: predicate)

        let events = ekEvents.compactMap { event -> CalendarEventItem? in
            guard let calendarID = event.calendar?.calendarIdentifier,
                  let startDate = event.startDate,
                  let endDate = event.endDate else {
                return nil
            }
            let eventID = event.eventIdentifier ?? "\(calendarID)-\(startDate.timeIntervalSince1970)"
            return CalendarEventItem(
                id: eventID,
                calendarID: calendarID,
                title: event.title ?? "",
                startDate: startDate,
                endDate: endDate,
                isAllDay: event.isAllDay,
                availability: Self.mapAvailability(event.availability),
                isCanceled: event.status == .canceled
            )
        }

        return CalendarSnapshot(
            permissionState: permissionState,
            activeEvents: events,
            availableCalendars: calendars
        )
    }

    func requestAccess(completion: @escaping (CalendarPermissionState) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { _, _ in
                DispatchQueue.main.async {
                    completion(Self.currentPermissionState())
                }
            }
        } else {
            eventStore.requestAccess(to: .event) { _, _ in
                DispatchQueue.main.async {
                    completion(Self.currentPermissionState())
                }
            }
        }
    }

    static func currentPermissionState() -> CalendarPermissionState {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            switch status {
            case .notDetermined:
                return .notDetermined
            case .restricted:
                return .restricted
            case .denied, .writeOnly:
                return .denied
            case .fullAccess:
                return .authorized
            @unknown default:
                return .denied
            }
        } else {
            switch status.rawValue {
            case EKAuthorizationStatus.notDetermined.rawValue:
                return .notDetermined
            case EKAuthorizationStatus.restricted.rawValue:
                return .restricted
            case EKAuthorizationStatus.denied.rawValue:
                return .denied
            case 3: // EKAuthorizationStatus.authorized
                return .authorized
            default:
                return .denied
            }
        }
    }

    private static func mapAvailability(_ availability: EKEventAvailability) -> CalendarAvailability {
        switch availability {
        case .busy:
            return .busy
        case .free:
            return .free
        case .tentative:
            return .tentative
        case .unavailable:
            return .unavailable
        case .notSupported:
            return .notSupported
        @unknown default:
            return .busy
        }
    }
}

/// Monitors Apple Calendar (EventKit) authorization, available calendars, and active events.
final class CalendarEventMonitor {
    var onUpdate: ((CalendarSnapshot) -> Void)?

    private let pollInterval: TimeInterval
    private let signalProvider: CalendarSignalProviding
    private var pollTimer: Timer?
    private var storeObserver: NSObjectProtocol?
    private(set) var lastSnapshot: CalendarSnapshot = .empty

    init(
        pollInterval: TimeInterval = 30.0,
        signalProvider: CalendarSignalProviding = SystemCalendarSignalProvider()
    ) {
        self.pollInterval = pollInterval
        self.signalProvider = signalProvider
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        registerObservers()
        pollNow()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let observer = storeObserver {
            NotificationCenter.default.removeObserver(observer)
            storeObserver = nil
        }
    }

    func pollNow(now: Date = Date()) {
        let snapshot = currentSnapshot(now: now)
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    func currentSnapshot(now: Date = Date()) -> CalendarSnapshot {
        signalProvider.currentSnapshot(now: now)
    }

    func requestAccess(completion: @escaping (CalendarPermissionState) -> Void) {
        signalProvider.requestAccess { [weak self] state in
            self?.pollNow()
            completion(state)
        }
    }

    func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func registerObservers() {
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pollNow()
        }
    }
}
