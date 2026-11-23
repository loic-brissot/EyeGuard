import XCTest
@testable import EyeGuardCore

final class CalendarBreakPolicyTests: XCTestCase {
    private let policy = CalendarBreakPolicy()
    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCalendar(id: String = "breaks-cal", title: String = "Breaks", source: String = "iCloud") -> CalendarDescriptor {
        CalendarDescriptor(id: id, title: title, sourceTitle: source)
    }

    private func makeEvent(
        id: String = "evt-1",
        calendarID: String = "breaks-cal",
        title: String = "Eye Break",
        startOffset: TimeInterval = 0,
        duration: TimeInterval = 15 * 60,
        isAllDay: Bool = false,
        availability: CalendarAvailability = .busy,
        isCanceled: Bool = false
    ) -> CalendarEventItem {
        let start = baseDate.addingTimeInterval(startOffset)
        return CalendarEventItem(
            id: id,
            calendarID: calendarID,
            title: title,
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            isAllDay: isAllDay,
            availability: availability,
            isCanceled: isCanceled
        )
    }

    // MARK: - Binding & Filtering (AC #1)

    func testDisabledSettingsNeverTriggerOrSuppress() {
        let settings = CalendarBreakSettings(isEnabled: false, selectedCalendarID: "breaks-cal")
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [makeEvent()],
            availableCalendars: [makeCalendar()]
        )

        let result = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate
        )

        XCTAssertEqual(result.decision, .none)
        XCTAssertFalse(result.shouldSuppressRegularBreak)
        XCTAssertFalse(result.isCalendarMissing)
        XCTAssertNil(result.nextBoundary)
    }

    func testFiltersBySelectedCalendarAndOptionalCaseInsensitiveTitleFilter() {
        let settings = CalendarBreakSettings(
            isEnabled: true,
            selectedCalendarID: "breaks-cal",
            selectedCalendarTitle: "Breaks",
            titleFilter: "  eye break  "
        )
        let matching = makeEvent(id: "match", calendarID: "breaks-cal", title: "Afternoon EYE BREAK")
        let wrongTitle = makeEvent(id: "wrong-title", calendarID: "breaks-cal", title: "Team Standup")
        let wrongCalendar = makeEvent(id: "wrong-cal", calendarID: "work-cal", title: "Eye Break")
        let allDay = makeEvent(id: "all-day", calendarID: "breaks-cal", title: "Eye Break", isAllDay: true)
        let canceled = makeEvent(id: "canceled", calendarID: "breaks-cal", title: "Eye Break", isCanceled: true)
        let freeEvent = makeEvent(id: "free", calendarID: "breaks-cal", title: "Free Eye Break", availability: .free)

        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [wrongTitle, wrongCalendar, allDay, canceled, freeEvent, matching],
            availableCalendars: [makeCalendar(id: "breaks-cal"), makeCalendar(id: "work-cal", title: "Work")]
        )

        let occurrences = policy.matchingOccurrences(settings: settings, snapshot: snapshot)
        XCTAssertEqual(occurrences.map(\.eventID), ["free", "match"])
    }

    func testEmptyTitleFilterMatchesAllNonAllDayNonCanceledEventsInSelectedCalendar() {
        let settings = CalendarBreakSettings(
            isEnabled: true,
            selectedCalendarID: "breaks-cal",
            titleFilter: "   "
        )
        let e1 = makeEvent(id: "e1", title: "Lunch Walk", startOffset: 600)
        let e2 = makeEvent(id: "e2", title: "Stretch", startOffset: 0)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [e1, e2],
            availableCalendars: [makeCalendar()]
        )

        let occurrences = policy.matchingOccurrences(settings: settings, snapshot: snapshot)
        XCTAssertEqual(occurrences.map(\.eventID), ["e2", "e1"])
    }

    // MARK: - Timing, Duration & Postpone End-Time Retention (AC #2)

    func testTriggersAtExactEventStartAndSpansExactDuration() {
        let settings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let event = makeEvent(startOffset: 0, duration: 15 * 60)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event],
            availableCalendars: [makeCalendar()]
        )

        // 1 second before start: within suppression lead, does not trigger yet
        let before = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate.addingTimeInterval(-1)
        )
        XCTAssertEqual(before.decision, .none)
        XCTAssertTrue(before.shouldSuppressRegularBreak)
        XCTAssertEqual(before.nextBoundary, baseDate)

        // At exact start: triggers for full 900 seconds
        let atStart = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate
        )
        XCTAssertEqual(atStart.decision, .trigger(CalendarBreakOccurrence(event: event), remainingSeconds: 900))
        XCTAssertTrue(atStart.shouldSuppressRegularBreak)
    }

    func testPostponingCalendarBreakRetainsOriginalEndTimeUponResume() {
        let settings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let event = makeEvent(startOffset: 0, duration: 15 * 60) // 14:00 to 14:15
        let occurrence = CalendarBreakOccurrence(event: event)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event],
            availableCalendars: [makeCalendar()]
        )

        // User postpones by 5 minutes at 14:02 (until 14:07)
        var state = CalendarBreakRuntimeState()
        state.activeOccurrence = occurrence
        state.postpone(occurrence, until: baseDate.addingTimeInterval(7 * 60))

        // At 14:05: still postponed, regular breaks suppressed, nextBoundary is 14:07
        let midPostpone = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: state,
            now: baseDate.addingTimeInterval(5 * 60)
        )
        XCTAssertEqual(midPostpone.decision, .none)
        XCTAssertTrue(midPostpone.shouldSuppressRegularBreak)
        XCTAssertEqual(midPostpone.nextBoundary, baseDate.addingTimeInterval(7 * 60))

        // At 14:07: resumes with 8 minutes (480s) remaining until original 14:15 end time!
        let atResume = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: midPostpone.nextState,
            now: baseDate.addingTimeInterval(7 * 60)
        )
        XCTAssertEqual(atResume.decision, .resumePostponed(occurrence, remainingSeconds: 8 * 60))
        XCTAssertNil(atResume.nextState.postponedOccurrence)
        XCTAssertNil(atResume.nextState.postponeUntil)
    }

    func testPostponingPastOriginalEndTimeExpiresCleanly() {
        let settings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let event = makeEvent(startOffset: 0, duration: 10 * 60) // 10 min event
        let occurrence = CalendarBreakOccurrence(event: event)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event],
            availableCalendars: [makeCalendar()]
        )

        var state = CalendarBreakRuntimeState()
        // At 8 min in, user postpones 5 min (until 13 min > 10 min end)
        state.postpone(occurrence, until: baseDate.addingTimeInterval(13 * 60))

        // At 10 min (original event end): expires cleanly instead of extending past event end
        let atEnd = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: state,
            now: baseDate.addingTimeInterval(10 * 60)
        )
        XCTAssertEqual(atEnd.decision, .expired(occurrence))
        XCTAssertEqual(atEnd.nextState.handledOccurrences[occurrence.occurrenceKey], .expired)
        XCTAssertNil(atEnd.nextState.postponedOccurrence)
    }

    func testRegularBreakSuppressionLeadWindow() {
        let settings = CalendarBreakSettings(
            isEnabled: true,
            selectedCalendarID: "breaks-cal",
            suppressionLeadSeconds: 5 * 60
        )
        let event = makeEvent(startOffset: 10 * 60, duration: 15 * 60)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event],
            availableCalendars: [makeCalendar()]
        )

        // 6 min before start -> not suppressed
        let sixMinBefore = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate.addingTimeInterval(4 * 60)
        )
        XCTAssertFalse(sixMinBefore.shouldSuppressRegularBreak)

        // 4 min before start -> suppressed
        let fourMinBefore = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate.addingTimeInterval(6 * 60)
        )
        XCTAssertTrue(fourMinBefore.shouldSuppressRegularBreak)
        XCTAssertEqual(fourMinBefore.suppressedByOccurrence?.eventID, event.id)
    }

    // MARK: - Missing / Synced Calendars & Event Edits (AC #3)

    func testMissingCalendarReportsMissingAndRecoversWhenSyncedBack() {
        let settings = CalendarBreakSettings(
            isEnabled: true,
            selectedCalendarID: "breaks-cal",
            selectedCalendarTitle: "Breaks"
        )
        let event = makeEvent(startOffset: 0, duration: 15 * 60)

        // Calendar temporarily missing from EventKit sync
        let missingSnapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event],
            availableCalendars: [makeCalendar(id: "other-cal", title: "Work")]
        )

        let missingResult = policy.evaluate(
            settings: settings,
            snapshot: missingSnapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate
        )
        XCTAssertTrue(missingResult.isCalendarMissing)
        XCTAssertTrue(missingResult.nextState.isCalendarMissing)
        XCTAssertEqual(missingResult.decision, .none)
        XCTAssertNil(missingResult.nextBoundary)

        // Calendar reappears in subsequent sync snapshot
        let syncedSnapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event],
            availableCalendars: [makeCalendar(id: "other-cal", title: "Work"), makeCalendar(id: "breaks-cal", title: "Breaks")]
        )

        let recoveredResult = policy.evaluate(
            settings: settings,
            snapshot: syncedSnapshot,
            state: missingResult.nextState,
            now: baseDate.addingTimeInterval(60)
        )
        XCTAssertFalse(recoveredResult.isCalendarMissing)
        XCTAssertFalse(recoveredResult.nextState.isCalendarMissing)
        XCTAssertEqual(recoveredResult.decision, .trigger(CalendarBreakOccurrence(event: event), remainingSeconds: 14 * 60))
    }

    func testActiveEventDeletedDuringSyncCancelsCleanly() {
        let settings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let event = makeEvent(startOffset: 0, duration: 15 * 60)
        let occurrence = CalendarBreakOccurrence(event: event)
        var state = CalendarBreakRuntimeState()
        state.activeOccurrence = occurrence

        let emptyEventsSnapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [],
            availableCalendars: [makeCalendar()]
        )

        let result = policy.evaluate(
            settings: settings,
            snapshot: emptyEventsSnapshot,
            state: state,
            now: baseDate.addingTimeInterval(2 * 60)
        )
        XCTAssertEqual(result.decision, .activeEventRemoved(occurrence))
        XCTAssertEqual(result.nextState.handledOccurrences[occurrence.occurrenceKey], .eventRemoved)
        XCTAssertNil(result.nextState.activeOccurrence)
    }

    func testRescheduledEventProducesNewOccurrenceKey() {
        let settings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let original = makeEvent(id: "evt-1", startOffset: 0, duration: 10 * 60)
        let originalOccurrence = CalendarBreakOccurrence(event: original)
        var state = CalendarBreakRuntimeState()
        state.markHandled(originalOccurrence, status: .completed)

        let rescheduled = makeEvent(id: "evt-1", startOffset: 3600, duration: 10 * 60)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [rescheduled],
            availableCalendars: [makeCalendar()]
        )

        let result = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: state,
            now: baseDate.addingTimeInterval(3600)
        )
        XCTAssertEqual(result.decision, .trigger(CalendarBreakOccurrence(event: rescheduled), remainingSeconds: 600))
    }

    // MARK: - Sleep / Wake Recovery (AC #3)

    func testSleepWakeCreditsAwayTimeAndExpiresOrResumesAccurately() {
        let settings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let event = makeEvent(startOffset: 0, duration: 10 * 60) // 10:00 - 10:10
        let occurrence = CalendarBreakOccurrence(event: event)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event],
            availableCalendars: [makeCalendar()]
        )

        // Case 1: Slept 10:01 - 10:09 (80% overlap >= threshold) -> creditedAway
        let awayCredited = DateInterval(start: baseDate.addingTimeInterval(60), end: baseDate.addingTimeInterval(9 * 60))
        let creditedResult = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate.addingTimeInterval(9 * 60),
            awayInterval: awayCredited
        )
        XCTAssertEqual(creditedResult.decision, .creditedAway(occurrence))
        XCTAssertEqual(creditedResult.nextState.handledOccurrences[occurrence.occurrenceKey], .creditedAway)

        // Case 2: Slept 09:50 - 10:15 (woke after windowEnd) -> creditedAway
        let awayPastEnd = DateInterval(start: baseDate.addingTimeInterval(-600), end: baseDate.addingTimeInterval(15 * 60))
        let pastEndResult = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate.addingTimeInterval(15 * 60),
            awayInterval: awayPastEnd
        )
        XCTAssertEqual(pastEndResult.decision, .creditedAway(occurrence))

        // Case 3: Slept 10:00 - 10:03 (only 30% away) -> wakes mid-event with 7 min remaining
        let shortAway = DateInterval(start: baseDate, end: baseDate.addingTimeInterval(3 * 60))
        let midEventResult = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate.addingTimeInterval(3 * 60),
            awayInterval: shortAway
        )
        XCTAssertEqual(midEventResult.decision, .trigger(occurrence, remainingSeconds: 7 * 60))
    }

    // MARK: - Smart Pause, Night Lock & Permissions

    func testCalendarBreakDoesNotSelfBlockWithCalendarPausePolicy() {
        let breakSettings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let pauseSettings = CalendarPauseSettings(isEnabled: true, selectedCalendarIDs: [])
        let breakEvent = makeEvent(id: "break-1", calendarID: "breaks-cal", title: "Eye Break", startOffset: 0, duration: 15 * 60)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [breakEvent],
            availableCalendars: [makeCalendar(id: "breaks-cal")]
        )

        let smartPause = SmartPausePolicy().evaluate(
            meetingSettings: MeetingAutoPauseSettings(isEnabled: false),
            calendarSettings: pauseSettings,
            calendarBreakSettings: breakSettings,
            calendarSnapshot: snapshot,
            focusAppSettings: FocusAppPauseSettings(fullscreenPauseEnabled: false, deepFocusApps: []),
            idleSettings: IdleNaturalBreakSettings(isEnabled: false),
            isAudioInputActive: false,
            isFrontmostFullscreen: false,
            runningApps: [],
            now: baseDate
        )
        XCTAssertFalse(smartPause.isPaused)

        let breakEval = policy.evaluate(
            settings: breakSettings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate,
            smartPauseEvaluation: smartPause
        )
        XCTAssertEqual(breakEval.decision, .trigger(CalendarBreakOccurrence(event: breakEvent), remainingSeconds: 15 * 60))
    }

    func testRealSmartPauseDefersCalendarBreakAndNightLockSuppresses() {
        let settings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let event = makeEvent(startOffset: 0, duration: 15 * 60)
        let occurrence = CalendarBreakOccurrence(event: event)
        let snapshot = CalendarSnapshot(
            permissionState: .authorized,
            activeEvents: [event],
            availableCalendars: [makeCalendar()]
        )

        let screenSharingPause = SmartPauseEvaluation(
            isPaused: true,
            reason: .screenRecordingOrSharing(source: "Zoom"),
            matchedAppName: "Zoom",
            matchedBundleID: "us.zoom.xos"
        )
        let deferred = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate,
            smartPauseEvaluation: screenSharingPause
        )
        XCTAssertEqual(deferred.decision, .deferredBySmartPause(occurrence, reason: .screenRecordingOrSharing(source: "Zoom")))
        XCTAssertEqual(deferred.nextState.deferredOccurrenceKey, occurrence.occurrenceKey)

        let nightLocked = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate,
            isNightLocked: true
        )
        XCTAssertEqual(nightLocked.decision, .none)
        XCTAssertFalse(nightLocked.shouldSuppressRegularBreak)
    }

    func testUnauthorizedPermissionDoesNotTriggerOrMarkMissing() {
        let settings = CalendarBreakSettings(isEnabled: true, selectedCalendarID: "breaks-cal")
        let snapshot = CalendarSnapshot(
            permissionState: .denied,
            activeEvents: [makeEvent()],
            availableCalendars: []
        )

        let result = policy.evaluate(
            settings: settings,
            snapshot: snapshot,
            state: CalendarBreakRuntimeState(),
            now: baseDate
        )
        XCTAssertEqual(result.decision, .none)
        XCTAssertFalse(result.isCalendarMissing)
    }
}
