import XCTest
@testable import EyeGuardCore

final class PlannedBreakPolicyTests: XCTestCase {
    private let policy = PlannedBreakPolicy()

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeDate(year: Int = 2026, month: Int = 11, day: Int = 23, hour: Int, minute: Int, second: Int = 0) -> Date {
        let calendar = makeCalendar()
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        ))!
    }

    func testSettingsCRUDAndCodableRoundTrip() throws {
        let lunch = PlannedBreakSchedule(
            name: "Lunch",
            hour: 12,
            minute: 0,
            durationMinutes: 30,
            weekdays: PlannedBreakSchedule.workWeekdays
        )
        let walk = PlannedBreakSchedule(
            name: "Afternoon Walk",
            hour: 15,
            minute: 30,
            durationMinutes: 15,
            weekdays: PlannedBreakSchedule.allWeekdays
        )

        var settings = PlannedBreakSettings()
            .adding(lunch)
            .adding(walk)
        XCTAssertEqual(settings.schedules.count, 2)

        var updatedLunch = lunch
        updatedLunch.name = "Long Lunch"
        updatedLunch.durationSeconds = 45 * 60
        settings = settings.updating(updatedLunch)
        XCTAssertEqual(settings.schedules.first(where: { $0.id == lunch.id })?.name, "Long Lunch")
        XCTAssertEqual(settings.schedules.first(where: { $0.id == lunch.id })?.durationMinutes, 45)

        settings = settings.toggling(id: walk.id)
        XCTAssertEqual(settings.schedules.first(where: { $0.id == walk.id })?.isEnabled, false)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PlannedBreakSettings.self, from: data)
        XCTAssertEqual(decoded, settings)

        settings = settings.removing(id: lunch.id)
        XCTAssertEqual(settings.schedules.map(\.id), [walk.id])
    }

    func testWeekdayFilteringAndMidnightBoundary() {
        let calendar = makeCalendar()
        // 2026-11-23 is Monday (weekday = 2)
        let monday = makeDate(day: 23, hour: 12, minute: 0)
        XCTAssertEqual(calendar.component(.weekday, from: monday), 2)

        let weekendOnly = PlannedBreakSchedule(
            name: "Weekend Pause",
            hour: 12,
            minute: 0,
            durationMinutes: 20,
            weekdays: PlannedBreakSchedule.weekendWeekdays
        )
        let mondayNight = PlannedBreakSchedule(
            name: "Late Stretch",
            hour: 23,
            minute: 50,
            durationMinutes: 30,
            weekdays: [2]
        )

        let settings = PlannedBreakSettings(schedules: [weekendOnly, mondayNight])

        // On Monday 12:00, weekendOnly should not trigger.
        let noonResult = policy.evaluate(
            settings: settings,
            state: PlannedBreakRuntimeState(),
            now: monday,
            calendar: calendar
        )
        XCTAssertEqual(noonResult.decision, .none)
        XCTAssertFalse(noonResult.shouldSuppressRegularBreak)

        // Crossing midnight into Tuesday 00:05 should still find Monday's 23:50-00:20 window.
        let tuesdayAfterMidnight = makeDate(day: 24, hour: 0, minute: 5)
        let midnightResult = policy.evaluate(
            settings: settings,
            state: PlannedBreakRuntimeState(),
            now: tuesdayAfterMidnight,
            calendar: calendar
        )
        if case .trigger(let occurrence, let remaining) = midnightResult.decision {
            XCTAssertEqual(occurrence.schedule.id, mondayNight.id)
            XCTAssertEqual(remaining, 15 * 60)
        } else {
            XCTFail("Expected midnight-spanning planned break to trigger, got \(midnightResult.decision)")
        }
    }

    func testRegularIntervalBreakSuppressionInLeadAndActiveWindows() {
        let calendar = makeCalendar()
        let lunch = PlannedBreakSchedule(
            name: "Lunch",
            hour: 12,
            minute: 0,
            durationMinutes: 30,
            weekdays: PlannedBreakSchedule.allWeekdays
        )
        let settings = PlannedBreakSettings(schedules: [lunch], suppressionLeadSeconds: 5 * 60)

        // 11:50 -> outside 5-minute lead window -> do not suppress
        let beforeLead = makeDate(hour: 11, minute: 50)
        let beforeResult = policy.evaluate(settings: settings, state: PlannedBreakRuntimeState(), now: beforeLead, calendar: calendar)
        XCTAssertFalse(beforeResult.shouldSuppressRegularBreak)
        XCTAssertEqual(beforeResult.decision, .none)

        // 11:56 -> inside 5-minute lead window -> suppress regular interval break
        let insideLead = makeDate(hour: 11, minute: 56)
        let leadResult = policy.evaluate(settings: settings, state: PlannedBreakRuntimeState(), now: insideLead, calendar: calendar)
        XCTAssertTrue(leadResult.shouldSuppressRegularBreak)
        XCTAssertEqual(leadResult.suppressedByOccurrence?.schedule.id, lunch.id)
        XCTAssertEqual(leadResult.decision, .none)

        // 12:00 -> triggers planned break and suppresses regular interval break
        let atStart = makeDate(hour: 12, minute: 0)
        let startResult = policy.evaluate(settings: settings, state: PlannedBreakRuntimeState(), now: atStart, calendar: calendar)
        XCTAssertTrue(startResult.shouldSuppressRegularBreak)
        if case .trigger(let occurrence, let remaining) = startResult.decision {
            XCTAssertEqual(occurrence.schedule.id, lunch.id)
            XCTAssertEqual(remaining, 30 * 60)
        } else {
            XCTFail("Expected planned break to trigger at 12:00")
        }
    }

    func testSmartPauseDefersPlannedBreakAndResumesAfterMeetingEnds() {
        let calendar = makeCalendar()
        let walk = PlannedBreakSchedule(
            name: "Afternoon Walk",
            hour: 15,
            minute: 0,
            durationMinutes: 20,
            weekdays: PlannedBreakSchedule.allWeekdays
        )
        let settings = PlannedBreakSettings(schedules: [walk])
        let meetingEvaluation = SmartPauseEvaluation(
            isPaused: true,
            reason: .meetingOrCall(appName: "Zoom"),
            matchedAppName: "Zoom",
            matchedBundleID: "us.zoom.xos"
        )

        // At 15:00 during a meeting -> deferred
        let atStart = makeDate(hour: 15, minute: 0)
        let deferredResult = policy.evaluate(
            settings: settings,
            state: PlannedBreakRuntimeState(),
            now: atStart,
            calendar: calendar,
            smartPauseEvaluation: meetingEvaluation
        )
        if case .deferredBySmartPause(let occurrence, let reason) = deferredResult.decision {
            XCTAssertEqual(occurrence.schedule.id, walk.id)
            XCTAssertEqual(reason, .meetingOrCall(appName: "Zoom"))
            XCTAssertEqual(deferredResult.nextState.deferredOccurrenceKey, occurrence.occurrenceKey)
        } else {
            XCTFail("Expected planned break to defer during meeting")
        }

        // Meeting ends at 15:05 -> triggers for remaining 15 minutes
        let meetingEnded = makeDate(hour: 15, minute: 5)
        let resumedResult = policy.evaluate(
            settings: settings,
            state: deferredResult.nextState,
            now: meetingEnded,
            calendar: calendar,
            smartPauseEvaluation: .activeNone
        )
        if case .trigger(let occurrence, let remaining) = resumedResult.decision {
            XCTAssertEqual(occurrence.schedule.id, walk.id)
            XCTAssertEqual(remaining, 15 * 60)
            XCTAssertNil(resumedResult.nextState.deferredOccurrenceKey)
        } else {
            XCTFail("Expected deferred planned break to trigger when meeting ended")
        }

        // If meeting lasted past 15:20 -> expires cleanly without nagging
        let pastWindow = makeDate(hour: 15, minute: 21)
        let expiredResult = policy.evaluate(
            settings: settings,
            state: deferredResult.nextState,
            now: pastWindow,
            calendar: calendar,
            smartPauseEvaluation: .activeNone
        )
        if case .expired(let occurrence) = expiredResult.decision {
            XCTAssertEqual(occurrence.schedule.id, walk.id)
            XCTAssertEqual(expiredResult.nextState.handledOccurrences[occurrence.occurrenceKey], .expired)
        } else {
            XCTFail("Expected deferred planned break to expire past window end")
        }
    }

    func testCreditsAwayTimeDuringPlannedBreakWindow() {
        let calendar = makeCalendar()
        let lunch = PlannedBreakSchedule(
            name: "Lunch",
            hour: 12,
            minute: 0,
            durationMinutes: 30,
            weekdays: PlannedBreakSchedule.allWeekdays
        )
        let settings = PlannedBreakSettings(schedules: [lunch])

        // User locked screen from 12:00 to 12:25 (25m >= 80% of 30m) and returned at 12:25
        let returnTime = makeDate(hour: 12, minute: 25)
        let awayInterval = DateInterval(start: makeDate(hour: 12, minute: 0), end: returnTime)
        let creditedResult = policy.evaluate(
            settings: settings,
            state: PlannedBreakRuntimeState(),
            now: returnTime,
            calendar: calendar,
            awayInterval: awayInterval
        )
        if case .creditedAway(let occurrence) = creditedResult.decision {
            XCTAssertEqual(occurrence.schedule.id, lunch.id)
            XCTAssertEqual(creditedResult.nextState.handledOccurrences[occurrence.occurrenceKey], .creditedAway)
        } else {
            XCTFail("Expected away time to credit the planned break")
        }

        // Subsequent evaluation at 12:26 must not re-trigger
        let afterReturn = policy.evaluate(
            settings: settings,
            state: creditedResult.nextState,
            now: makeDate(hour: 12, minute: 26),
            calendar: calendar
        )
        XCTAssertEqual(afterReturn.decision, .none)
        XCTAssertFalse(afterReturn.shouldSuppressRegularBreak)
    }

    func testMultiplePlannedBreaksAndNextBoundaryCalculation() {
        let calendar = makeCalendar()
        let morning = PlannedBreakSchedule(
            name: "Morning Coffee",
            hour: 10,
            minute: 30,
            durationMinutes: 10,
            weekdays: PlannedBreakSchedule.allWeekdays
        )
        let afternoon = PlannedBreakSchedule(
            name: "Afternoon Walk",
            hour: 15,
            minute: 0,
            durationMinutes: 15,
            weekdays: PlannedBreakSchedule.allWeekdays
        )
        let settings = PlannedBreakSettings(schedules: [afternoon, morning])

        let atNine = makeDate(hour: 9, minute: 0)
        let firstBoundary = policy.nextBoundary(settings: settings, now: atNine, calendar: calendar)
        XCTAssertEqual(firstBoundary, makeDate(hour: 10, minute: 30))

        // Mark morning break completed -> next boundary is 15:00
        let morningOcc = PlannedBreakOccurrence(schedule: morning, windowStart: makeDate(hour: 10, minute: 30))
        var state = PlannedBreakRuntimeState()
        state.markHandled(morningOcc, status: .completed)

        let atTenForty = makeDate(hour: 10, minute: 40)
        let secondBoundary = policy.nextBoundary(settings: settings, state: state, now: atTenForty, calendar: calendar)
        XCTAssertEqual(secondBoundary, makeDate(hour: 15, minute: 0))
    }

    func testNightLockAndTemporaryDisablePreventPlannedBreakTrigger() {
        let calendar = makeCalendar()
        let lateBreak = PlannedBreakSchedule(
            name: "Stretch",
            hour: 22,
            minute: 30,
            durationMinutes: 15,
            weekdays: PlannedBreakSchedule.allWeekdays
        )
        let settings = PlannedBreakSettings(schedules: [lateBreak])
        let now = makeDate(hour: 22, minute: 30)

        let nightResult = policy.evaluate(
            settings: settings,
            state: PlannedBreakRuntimeState(),
            now: now,
            calendar: calendar,
            isNightLocked: true
        )
        XCTAssertEqual(nightResult.decision, .none)
        XCTAssertFalse(nightResult.shouldSuppressRegularBreak)

        let disabledResult = policy.evaluate(
            settings: settings,
            state: PlannedBreakRuntimeState(),
            now: now,
            calendar: calendar,
            isTemporarilyDisabled: true
        )
        XCTAssertEqual(disabledResult.decision, .none)
        XCTAssertFalse(disabledResult.shouldSuppressRegularBreak)
    }
}
