import XCTest
@testable import EyeGuardCore

final class CalendarPausePolicyTests: XCTestCase {
    private let policy = CalendarPausePolicy()
    private let smartPausePolicy = SmartPausePolicy()
    private let baseDate = Date(timeIntervalSince1970: 1_760_000_000)

    // MARK: - Active Non-All-Day Busy Events

    func testActiveNonAllDayBusyEventPausesBreaks() {
        let start = baseDate.addingTimeInterval(-600)
        let end = baseDate.addingTimeInterval(1200)
        let event = CalendarEventItem(
            id: "evt-1",
            calendarID: "cal-work",
            title: "Design Review",
            startDate: start,
            endDate: end,
            isAllDay: false,
            availability: .busy,
            isCanceled: false
        )
        let settings = CalendarPauseSettings(isEnabled: true)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event]
        )

        let evaluation = policy.evaluate(settings: settings, snapshot: snapshot, now: baseDate)
        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .calendarEvent(title: "Design Review"))
        XCTAssertEqual(evaluation.matchedAppName, "Design Review")
        XCTAssertNil(evaluation.matchedBundleID)

        // Exact startDate is inclusive; exact endDate is exclusive
        XCTAssertTrue(policy.evaluate(settings: settings, snapshot: snapshot, now: start).isPaused)
        XCTAssertEqual(policy.evaluate(settings: settings, snapshot: snapshot, now: end), .activeNone)
    }

    func testDisabledPolicyNeverPausesEvenWithActiveBusyEvent() {
        let event = CalendarEventItem(
            id: "evt-1",
            calendarID: "cal-work",
            title: "1:1 Sync",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(900)
        )
        let settings = CalendarPauseSettings(isEnabled: false)
        let snapshot = CalendarSnapshot(permissionState: .authorized, activeEvents: [event])

        XCTAssertEqual(policy.evaluate(settings: settings, snapshot: snapshot, now: baseDate), .activeNone)
    }

    // MARK: - Filtering: All-Day, Free, Canceled

    func testAllDayEventsAreFilteredOut() {
        let allDayEvent = CalendarEventItem(
            id: "evt-all-day",
            calendarID: "cal-work",
            title: "Company Holiday",
            startDate: baseDate.addingTimeInterval(-3600),
            endDate: baseDate.addingTimeInterval(3600 * 20),
            isAllDay: true,
            availability: .busy
        )
        let settings = CalendarPauseSettings(isEnabled: true)
        let snapshot = CalendarSnapshot(permissionState: .authorized, activeEvents: [allDayEvent])

        XCTAssertEqual(policy.evaluate(settings: settings, snapshot: snapshot, now: baseDate), .activeNone)
    }

    func testFreeTentativeAndCanceledEventsAreIgnored() {
        let freeEvent = CalendarEventItem(
            id: "evt-free",
            calendarID: "cal-work",
            title: "Focus Hold",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(900),
            availability: .free
        )
        let tentativeEvent = CalendarEventItem(
            id: "evt-tentative",
            calendarID: "cal-work",
            title: "Optional Coffee",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(900),
            availability: .tentative
        )
        let canceledEvent = CalendarEventItem(
            id: "evt-canceled",
            calendarID: "cal-work",
            title: "Canceled Standup",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(900),
            availability: .busy,
            isCanceled: true
        )

        let settings = CalendarPauseSettings(isEnabled: true)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [freeEvent, tentativeEvent, canceledEvent]
        )

        XCTAssertEqual(policy.evaluate(settings: settings, snapshot: snapshot, now: baseDate), .activeNone)
    }

    // MARK: - Overlapping Events

    func testOverlappingEventsStayPausedUntilLastQualifyingEventEnds() {
        let shortEvent = CalendarEventItem(
            id: "evt-short",
            calendarID: "cal-work",
            title: "Quick Standup",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(300) // ends at +5m
        )
        let longEvent = CalendarEventItem(
            id: "evt-long",
            calendarID: "cal-work",
            title: "Architecture Deep Dive",
            startDate: baseDate,
            endDate: baseDate.addingTimeInterval(1800) // ends at +30m
        )
        let settings = CalendarPauseSettings(isEnabled: true)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [shortEvent, longEvent]
        )

        // At +2m: both overlapping events active -> deterministically picks latest-ending event
        let atTwoMinutes = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            now: baseDate.addingTimeInterval(120)
        )
        XCTAssertTrue(atTwoMinutes.isPaused)
        XCTAssertEqual(atTwoMinutes.reason, .calendarEvent(title: "Architecture Deep Dive"))

        // At +10m: shortEvent ended, longEvent still active -> stays paused
        let atTenMinutes = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            now: baseDate.addingTimeInterval(600)
        )
        XCTAssertTrue(atTenMinutes.isPaused)
        XCTAssertEqual(atTenMinutes.reason, .calendarEvent(title: "Architecture Deep Dive"))

        // At +30m: all overlapping events ended -> resumes
        let atThirtyMinutes = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            now: baseDate.addingTimeInterval(1800)
        )
        XCTAssertEqual(atThirtyMinutes, .activeNone)
    }

    // MARK: - Selected Calendar Filtering

    func testSelectedCalendarFiltering() {
        let personalEvent = CalendarEventItem(
            id: "evt-personal",
            calendarID: "cal-personal",
            title: "Dentist",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(900)
        )
        let workEvent = CalendarEventItem(
            id: "evt-work",
            calendarID: "cal-work",
            title: "Sprint Planning",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(900)
        )
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [personalEvent, workEvent]
        )

        // Only monitoring cal-work -> personalEvent ignored, workEvent matches
        let workOnly = CalendarPauseSettings(isEnabled: true, selectedCalendarIDs: ["cal-work"])
        let workEval = policy.evaluate(settings: workOnly, snapshot: snapshot, now: baseDate)
        XCTAssertEqual(workEval.reason, .calendarEvent(title: "Sprint Planning"))

        // Only monitoring cal-other -> neither matches
        let otherOnly = CalendarPauseSettings(isEnabled: true, selectedCalendarIDs: ["cal-other"])
        XCTAssertEqual(policy.evaluate(settings: otherOnly, snapshot: snapshot, now: baseDate), .activeNone)
    }

    // MARK: - Break Action Configuration

    func testBreakActionDefaultsAndCodableRoundTrip() throws {
        let defaultSettings = CalendarPauseSettings()
        XCTAssertFalse(defaultSettings.isEnabled)
        XCTAssertTrue(defaultSettings.selectedCalendarIDs.isEmpty)
        XCTAssertEqual(defaultSettings.breakAction, .postpone)

        let customSettings = CalendarPauseSettings(
            isEnabled: true,
            selectedCalendarIDs: ["cal-work", "cal-team"],
            breakAction: .skip
        )
        let data = try JSONEncoder().encode(customSettings)
        let decoded = try JSONDecoder().decode(CalendarPauseSettings.self, from: data)
        XCTAssertEqual(decoded, customSettings)
    }

    // MARK: - Permission States

    func testPermissionDeniedRestrictedOrNotDeterminedNeverPauses() {
        let event = CalendarEventItem(
            id: "evt-1",
            calendarID: "cal-work",
            title: "All Hands",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(900)
        )
        let settings = CalendarPauseSettings(isEnabled: true)

        for state in [CalendarPermissionState.denied, .restricted, .notDetermined] {
            let snapshot = CalendarSnapshot(permissionState: state, activeEvents: [event])
            XCTAssertEqual(
                policy.evaluate(settings: settings, snapshot: snapshot, now: baseDate),
                .activeNone,
                "Permission state \(state) must never pause breaks"
            )
        }
    }

    // MARK: - Unified SmartPausePolicy Precedence

    func testUnifiedSmartPausePrecedenceWithCalendarEvent() {
        let calendarSettings = CalendarPauseSettings(isEnabled: true)
        let event = CalendarEventItem(
            id: "evt-1",
            calendarID: "cal-work",
            title: "Product Sync",
            startDate: baseDate.addingTimeInterval(-300),
            endDate: baseDate.addingTimeInterval(900)
        )
        let calendarSnapshot = CalendarSnapshot(permissionState: .authorized, activeEvents: [event])
        let focusSettings = FocusAppPauseSettings(
            fullscreenPauseEnabled: true,
            deepFocusApps: [DeepFocusAppRule(identifier: "com.apple.dt.Xcode", triggerMode: .whenFrontmost)]
        )
        let xcode = RunningAppInfo(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", isFrontmost: true)

        // 1. Screen capture takes precedence over calendar event
        let duringScreenShare = smartPausePolicy.evaluate(
            screenCaptureSettings: ScreenCaptureSettings(isEnabled: true),
            screenCaptureSnapshot: ScreenCaptureSnapshot(isScreenSharingOrRecordingActive: true, activeSourceName: "Screen Sharing"),
            meetingSettings: MeetingAutoPauseSettings(isEnabled: true),
            calendarSettings: calendarSettings,
            calendarSnapshot: calendarSnapshot,
            focusAppSettings: focusSettings,
            isAudioInputActive: true,
            isFrontmostFullscreen: true,
            runningApps: [xcode],
            now: baseDate
        )
        XCTAssertEqual(duringScreenShare.reason, .screenRecordingOrSharing(source: "Screen Sharing"))

        // 2. Active meeting takes precedence over calendar event
        let duringMeeting = smartPausePolicy.evaluate(
            screenCaptureSettings: ScreenCaptureSettings(isEnabled: false),
            screenCaptureSnapshot: .inactive,
            meetingSettings: MeetingAutoPauseSettings(isEnabled: true),
            calendarSettings: calendarSettings,
            calendarSnapshot: calendarSnapshot,
            focusAppSettings: focusSettings,
            isAudioInputActive: true,
            isFrontmostFullscreen: true,
            runningApps: [xcode],
            now: baseDate
        )
        XCTAssertEqual(duringMeeting.reason, .meetingOrCall(appName: "Xcode"))

        // 3. Calendar event takes precedence over fullscreen & deep focus
        let duringCalendarOnly = smartPausePolicy.evaluate(
            screenCaptureSettings: ScreenCaptureSettings(isEnabled: false),
            screenCaptureSnapshot: .inactive,
            meetingSettings: MeetingAutoPauseSettings(isEnabled: true),
            calendarSettings: calendarSettings,
            calendarSnapshot: calendarSnapshot,
            focusAppSettings: focusSettings,
            isAudioInputActive: false,
            isFrontmostFullscreen: true,
            runningApps: [xcode],
            now: baseDate
        )
        XCTAssertEqual(duringCalendarOnly.reason, .calendarEvent(title: "Product Sync"))
    }
}
