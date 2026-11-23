import XCTest
@testable import EyeGuardCore

final class InputActivityDeferralPolicyTests: XCTestCase {
    private let policy = InputActivityDeferralPolicy()

    func testDisabledPolicyTriggersImmediatelyEvenDuringActiveTypingAndDragging() {
        let settings = InputDeferralSettings(isEnabled: false, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let activity = InputActivityState(
            secondsSinceLastKeystroke: 0.1,
            isMouseButtonDown: true,
            secondsSinceLastDragRelease: nil
        )

        let decision = policy.evaluate(settings: settings, activity: activity, waitDuration: 0)
        XCTAssertEqual(decision, .triggerNow)
    }

    func testDefersDuringActiveTypingWithinGraceWindow() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let activity = InputActivityState(secondsSinceLastKeystroke: 1.2)

        let decision = policy.evaluate(settings: settings, activity: activity, waitDuration: 2.0)
        XCTAssertEqual(decision, .deferBreak(reason: .typing, recheckAfter: 0.5))
    }

    func testTriggersOnceTypingGraceWindowElapses() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let activity = InputActivityState(secondsSinceLastKeystroke: 3.0)

        let decision = policy.evaluate(settings: settings, activity: activity, waitDuration: 3.0)
        XCTAssertEqual(decision, .triggerNow)
    }

    func testDefersWhileMouseButtonIsDownForDrag() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let activity = InputActivityState(
            secondsSinceLastKeystroke: 20.0,
            isMouseButtonDown: true,
            secondsSinceLastDragRelease: nil
        )

        let decision = policy.evaluate(settings: settings, activity: activity, waitDuration: 1.0)
        XCTAssertEqual(decision, .deferBreak(reason: .dragging, recheckAfter: 0.5))
    }

    func testDefersDuringGraceWindowAfterDragRelease() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let activity = InputActivityState(
            secondsSinceLastKeystroke: 15.0,
            isMouseButtonDown: false,
            secondsSinceLastDragRelease: 1.5
        )

        let decision = policy.evaluate(settings: settings, activity: activity, waitDuration: 5.0)
        XCTAssertEqual(decision, .deferBreak(reason: .dragging, recheckAfter: 0.5))
    }

    func testTriggersOnceDragReleaseGraceWindowElapses() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let activity = InputActivityState(
            secondsSinceLastKeystroke: 15.0,
            isMouseButtonDown: false,
            secondsSinceLastDragRelease: 3.1
        )

        let decision = policy.evaluate(settings: settings, activity: activity, waitDuration: 5.0)
        XCTAssertEqual(decision, .triggerNow)
    }

    func testDefersWithCombinedReasonWhenBothTypingAndDraggingActive() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let activity = InputActivityState(
            secondsSinceLastKeystroke: 0.5,
            isMouseButtonDown: true,
            secondsSinceLastDragRelease: nil
        )

        let decision = policy.evaluate(settings: settings, activity: activity, waitDuration: 0)
        XCTAssertEqual(decision, .deferBreak(reason: .typingAndDragging, recheckAfter: 0.5))
    }

    func testTriggersWhenMaxWaitThresholdIsReachedDespiteContinuousActivity() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let activity = InputActivityState(
            secondsSinceLastKeystroke: 0.1,
            isMouseButtonDown: true,
            secondsSinceLastDragRelease: nil
        )

        let decisionAtLimit = policy.evaluate(settings: settings, activity: activity, waitDuration: 60.0)
        XCTAssertEqual(decisionAtLimit, .triggerNow)

        let decisionPastLimit = policy.evaluate(settings: settings, activity: activity, waitDuration: 65.0)
        XCTAssertEqual(decisionPastLimit, .triggerNow)
    }

    func testRecheckIntervalClampsToRemainingMaxWaitThreshold() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 30.0)
        let activity = InputActivityState(secondsSinceLastKeystroke: 0.2)

        let decision = policy.evaluate(settings: settings, activity: activity, waitDuration: 29.8)
        guard case .deferBreak(let reason, let recheckAfter) = decision else {
            return XCTFail("Expected deferBreak decision")
        }
        XCTAssertEqual(reason, .typing)
        XCTAssertEqual(recheckAfter, 0.2, accuracy: 0.001)
    }

    func testIdleStateTriggersImmediately() {
        let settings = InputDeferralSettings(isEnabled: true, idleGraceWindow: 3.0, maxWaitThreshold: 60.0)
        let decision = policy.evaluate(settings: settings, activity: .idle, waitDuration: 0)
        XCTAssertEqual(decision, .triggerNow)
    }

    func testValidatedMaxWaitSecondsAllowsSupportedOptionsAndFallsBackToDefault() {
        XCTAssertEqual(InputDeferralSettings.validatedMaxWaitSeconds(30), 30)
        XCTAssertEqual(InputDeferralSettings.validatedMaxWaitSeconds(60), 60)
        XCTAssertEqual(InputDeferralSettings.validatedMaxWaitSeconds(120), 120)
        XCTAssertEqual(InputDeferralSettings.validatedMaxWaitSeconds(45), 60)
    }
}
