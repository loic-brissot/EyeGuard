import XCTest
@testable import EyeGuardCore

final class PreBreakHeadsUpTests: XCTestCase {
    private let policy = PreBreakHeadsUpPolicy()
    private let now = Date(timeIntervalSince1970: 10_000)

    func testLeadTimeOptionsAndValidation() {
        XCTAssertEqual(PreBreakLeadTime.allCases.map(\.rawValue), [0, 10, 20, 30])
        XCTAssertEqual(PreBreakLeadTime.validated(0), .off)
        XCTAssertEqual(PreBreakLeadTime.validated(10), .seconds10)
        XCTAssertEqual(PreBreakLeadTime.validated(20), .seconds20)
        XCTAssertEqual(PreBreakLeadTime.validated(30), .seconds30)
        XCTAssertEqual(PreBreakLeadTime.validated(99), .defaultLeadTime)
        XCTAssertEqual(PreBreakLeadTime.validated(-5), .defaultLeadTime)
    }

    func testEffectiveLeadTimeClampsToShortWorkDurations() {
        XCTAssertEqual(policy.effectiveLeadTimeSeconds(leadTime: .off, workDurationSeconds: 1_200), 0)
        XCTAssertEqual(policy.effectiveLeadTimeSeconds(leadTime: .seconds20, workDurationSeconds: 1_200), 20)
        XCTAssertEqual(policy.effectiveLeadTimeSeconds(leadTime: .seconds30, workDurationSeconds: 15), 14)
        XCTAssertEqual(policy.effectiveLeadTimeSeconds(leadTime: .seconds10, workDurationSeconds: 1), 0)
        XCTAssertEqual(policy.effectiveLeadTimeSeconds(leadTime: .seconds10, workDurationSeconds: 0), 0)
    }

    func testStateTransitionsFromInactiveToActiveToOverlayHandoff() {
        let workDuration = 1_200
        let leadTime: PreBreakLeadTime = .seconds20

        XCTAssertEqual(
            policy.state(remainingTime: 25, leadTime: leadTime, workDurationSeconds: workDuration, isWorkOrPostponeActive: true),
            .inactive
        )
        XCTAssertEqual(
            policy.state(remainingTime: 20.1, leadTime: leadTime, workDurationSeconds: workDuration, isWorkOrPostponeActive: true),
            .inactive
        )
        XCTAssertEqual(
            policy.state(remainingTime: 20.0, leadTime: leadTime, workDurationSeconds: workDuration, isWorkOrPostponeActive: true),
            .active(remainingSeconds: 20)
        )
        XCTAssertEqual(
            policy.state(remainingTime: 18.2, leadTime: leadTime, workDurationSeconds: workDuration, isWorkOrPostponeActive: true),
            .active(remainingSeconds: 19)
        )
        XCTAssertEqual(
            policy.state(remainingTime: 0.4, leadTime: leadTime, workDurationSeconds: workDuration, isWorkOrPostponeActive: true),
            .active(remainingSeconds: 1)
        )
        XCTAssertEqual(
            policy.state(remainingTime: 0, leadTime: leadTime, workDurationSeconds: workDuration, isWorkOrPostponeActive: true),
            .handoffToBreak
        )
        XCTAssertEqual(
            policy.state(remainingTime: -0.5, leadTime: leadTime, workDurationSeconds: workDuration, isWorkOrPostponeActive: true),
            .handoffToBreak
        )
    }

    func testOffLeadTimeNeverActivatesHeadsUpAndStillHandsOffAtZero() {
        XCTAssertEqual(
            policy.state(remainingTime: 15, leadTime: .off, workDurationSeconds: 1_200, isWorkOrPostponeActive: true),
            .inactive
        )
        XCTAssertEqual(
            policy.state(remainingTime: 0, leadTime: .off, workDurationSeconds: 1_200, isWorkOrPostponeActive: true),
            .handoffToBreak
        )
    }

    func testInactiveSessionRemainsInactive() {
        XCTAssertEqual(
            policy.state(remainingTime: 10, leadTime: .seconds20, workDurationSeconds: 1_200, isWorkOrPostponeActive: false),
            .inactive
        )
        XCTAssertEqual(
            policy.state(remainingTime: 0, leadTime: .seconds20, workDurationSeconds: 1_200, isWorkOrPostponeActive: false),
            .inactive
        )
    }

    func testSnoozeCancellationRespectsPostponeLimits() {
        XCTAssertEqual(
            policy.snooze(minutes: 1, totalPostponedTime: 0, maxTotalPostponeTime: 5 * 60),
            .cancelled(.snoozed(minutes: 1))
        )
        XCTAssertEqual(
            policy.snooze(minutes: 5, totalPostponedTime: 0, maxTotalPostponeTime: 5 * 60),
            .cancelled(.snoozed(minutes: 5))
        )
        XCTAssertNil(
            policy.snooze(minutes: 5, totalPostponedTime: 60, maxTotalPostponeTime: 5 * 60)
        )
        XCTAssertEqual(
            policy.snooze(minutes: 1, totalPostponedTime: 4 * 60, maxTotalPostponeTime: 5 * 60),
            .cancelled(.snoozed(minutes: 1))
        )
        XCTAssertNil(
            policy.snooze(minutes: 1, totalPostponedTime: 5 * 60, maxTotalPostponeTime: 5 * 60)
        )
    }

    func testSkipCancellation() {
        XCTAssertEqual(policy.skip(), .cancelled(.skipped))
    }

    func testCountdownTimingWakesAtHeadsUpLeadBoundaryEvenWithHiddenStatusCountdown() {
        let deadline = now.addingTimeInterval(1_200)
        let beforeWindow = CountdownTiming.plan(
            now: now,
            phase: .work(until: deadline),
            nightTransition: nil,
            overrideUntil: nil,
            showStatusCountdown: false,
            menuIsOpen: false,
            displaysAreActive: true,
            preBreakLeadTimeSeconds: 20
        )
        XCTAssertEqual(beforeWindow.deadline, deadline)
        XCTAssertEqual(beforeWindow.display, deadline.addingTimeInterval(-20))

        let insideWindow = CountdownTiming.plan(
            now: deadline.addingTimeInterval(-20),
            phase: .work(until: deadline),
            nightTransition: nil,
            overrideUntil: nil,
            showStatusCountdown: false,
            menuIsOpen: false,
            displaysAreActive: true,
            preBreakLeadTimeSeconds: 20
        )
        XCTAssertEqual(insideWindow.display, deadline.addingTimeInterval(-19))
    }

    func testCountdownTimingSupportsHeadsUpForPostponedPhase() {
        let postponeDeadline = now.addingTimeInterval(60)
        let beforePostponeHeadsUp = CountdownTiming.plan(
            now: now,
            phase: .postponed(until: postponeDeadline),
            nightTransition: nil,
            overrideUntil: nil,
            showStatusCountdown: false,
            menuIsOpen: false,
            displaysAreActive: true,
            preBreakLeadTimeSeconds: 10
        )
        XCTAssertEqual(beforePostponeHeadsUp.display, postponeDeadline.addingTimeInterval(-10))

        let insidePostponeHeadsUp = CountdownTiming.plan(
            now: postponeDeadline.addingTimeInterval(-9.4),
            phase: .postponed(until: postponeDeadline),
            nightTransition: nil,
            overrideUntil: nil,
            showStatusCountdown: false,
            menuIsOpen: false,
            displaysAreActive: true,
            preBreakLeadTimeSeconds: 10
        )
        XCTAssertEqual(insidePostponeHeadsUp.display!.timeIntervalSince(postponeDeadline.addingTimeInterval(-9)), 0, accuracy: 0.00001)
    }
}
