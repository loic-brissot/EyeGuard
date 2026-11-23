import XCTest
@testable import EyeGuardCore

final class BreakSkipPolicyTests: XCTestCase {
    private let policy = BreakSkipPolicy()

    func testStrictModeAlwaysHidesAndLocksSkip() {
        let settings = BreakSkipSettings(isStrictMode: true, skipDelaySeconds: 0)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(settings.allowsSkip)
        XCTAssertEqual(policy.state(settings: settings, breakStartTime: start, now: start), .hidden)
        XCTAssertEqual(policy.state(settings: settings, breakStartTime: start, now: start.addingTimeInterval(60)), .hidden)
        XCTAssertFalse(policy.isSkipUnlocked(settings: settings, breakStartTime: start, now: start.addingTimeInterval(60)))
        XCTAssertEqual(policy.remainingDelaySeconds(settings: settings, breakStartTime: start, now: start), 0)
    }

    func testZeroDelayUnlocksSkipImmediatelyWhenNotStrict() {
        let settings = BreakSkipSettings(isStrictMode: false, skipDelaySeconds: 0)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(settings.allowsSkip)
        XCTAssertEqual(policy.state(settings: settings, breakStartTime: start, now: start), .unlocked)
        XCTAssertTrue(policy.isSkipUnlocked(settings: settings, breakStartTime: start, now: start))
        XCTAssertEqual(policy.remainingDelaySeconds(settings: settings, breakStartTime: start, now: start), 0)
    }

    func testSkipDelayCountsDownAndUnlocksAfterDelayElapsed() {
        let settings = BreakSkipSettings(isStrictMode: false, skipDelaySeconds: 3)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(policy.state(settings: settings, breakStartTime: start, now: start), .locked(remainingSeconds: 3))
        XCTAssertFalse(policy.isSkipUnlocked(settings: settings, breakStartTime: start, now: start))

        XCTAssertEqual(
            policy.state(settings: settings, breakStartTime: start, now: start.addingTimeInterval(0.5)),
            .locked(remainingSeconds: 3)
        )
        XCTAssertEqual(
            policy.state(settings: settings, breakStartTime: start, now: start.addingTimeInterval(1.0)),
            .locked(remainingSeconds: 2)
        )
        XCTAssertEqual(
            policy.state(settings: settings, breakStartTime: start, now: start.addingTimeInterval(2.1)),
            .locked(remainingSeconds: 1)
        )
        XCTAssertEqual(
            policy.state(settings: settings, breakStartTime: start, now: start.addingTimeInterval(3.0)),
            .unlocked
        )
        XCTAssertTrue(policy.isSkipUnlocked(settings: settings, breakStartTime: start, now: start.addingTimeInterval(3.0)))
        XCTAssertEqual(policy.remainingDelaySeconds(settings: settings, breakStartTime: start, now: start.addingTimeInterval(3.0)), 0)
    }

    func testMissingBreakStartTimeKeepsSkipLockedWhenDelayConfigured() {
        let settings = BreakSkipSettings(isStrictMode: false, skipDelaySeconds: 5)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(policy.state(settings: settings, breakStartTime: nil, now: now), .locked(remainingSeconds: 5))
        XCTAssertFalse(policy.isSkipUnlocked(settings: settings, breakStartTime: nil, now: now))
    }

    func testNegativeSkipDelayIsClampedToZero() {
        let settings = BreakSkipSettings(isStrictMode: false, skipDelaySeconds: -5)
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(settings.skipDelaySeconds, 0)
        XCTAssertEqual(policy.state(settings: settings, breakStartTime: start, now: start), .unlocked)
    }
}
