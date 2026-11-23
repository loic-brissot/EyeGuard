import XCTest
@testable import EyeGuardCore

final class IdleNaturalBreakPolicyTests: XCTestCase {
    private let policy = IdleNaturalBreakPolicy()
    private let smartPausePolicy = SmartPausePolicy()

    func testBelowIdleThresholdStaysActive() {
        let settings = IdleNaturalBreakSettings(
            isEnabled: true,
            idlePauseThreshold: 120,
            naturalBreakDuration: 140
        )

        let result = policy.evaluate(
            settings: settings,
            currentState: .active,
            idleSeconds: 119.9,
            isFullscreenOrVideoActive: false,
            isOtherSmartPauseActive: false
        )

        XCTAssertEqual(result.nextState, .active)
        XCTAssertEqual(result.transition, .none)
    }

    func testReachingIdleThresholdEntersIdlePause() {
        let settings = IdleNaturalBreakSettings(
            isEnabled: true,
            idlePauseThreshold: 120,
            naturalBreakDuration: 140
        )

        let result = policy.evaluate(
            settings: settings,
            currentState: .active,
            idleSeconds: 120,
            isFullscreenOrVideoActive: false,
            isOtherSmartPauseActive: false
        )

        XCTAssertEqual(
            result.nextState,
            .idlePaused(idleSeconds: 120, qualifiedForNaturalBreak: false)
        )
        XCTAssertEqual(result.transition, .enterIdlePause)
    }

    func testReturningBeforeQualifyingNaturalBreakResumesPausedCountdown() {
        let settings = IdleNaturalBreakSettings(
            isEnabled: true,
            idlePauseThreshold: 120,
            naturalBreakDuration: 140
        )

        let midIdle = policy.evaluate(
            settings: settings,
            currentState: .idlePaused(idleSeconds: 120, qualifiedForNaturalBreak: false),
            idleSeconds: 135,
            isFullscreenOrVideoActive: false,
            isOtherSmartPauseActive: false
        )
        XCTAssertEqual(
            midIdle.nextState,
            .idlePaused(idleSeconds: 135, qualifiedForNaturalBreak: false)
        )
        XCTAssertEqual(midIdle.transition, .stayIdlePaused(qualifiedForNaturalBreak: false))

        let returnedEarly = policy.evaluate(
            settings: settings,
            currentState: midIdle.nextState,
            idleSeconds: 0.2,
            isFullscreenOrVideoActive: false,
            isOtherSmartPauseActive: false
        )
        XCTAssertEqual(returnedEarly.nextState, .active)
        XCTAssertEqual(returnedEarly.transition, .resumePausedCountdown)
    }

    func testReturningAfterQualifyingNaturalBreakCreditsBreakAndResetsWorkCycle() {
        let settings = IdleNaturalBreakSettings(
            isEnabled: true,
            idlePauseThreshold: 120,
            naturalBreakDuration: 140
        )

        let qualifiedIdle = policy.evaluate(
            settings: settings,
            currentState: .idlePaused(idleSeconds: 120, qualifiedForNaturalBreak: false),
            idleSeconds: 145,
            isFullscreenOrVideoActive: false,
            isOtherSmartPauseActive: false
        )
        XCTAssertEqual(
            qualifiedIdle.nextState,
            .idlePaused(idleSeconds: 145, qualifiedForNaturalBreak: true)
        )
        XCTAssertEqual(qualifiedIdle.transition, .stayIdlePaused(qualifiedForNaturalBreak: true))

        let returnedAfterBreak = policy.evaluate(
            settings: settings,
            currentState: qualifiedIdle.nextState,
            idleSeconds: 0.1,
            isFullscreenOrVideoActive: false,
            isOtherSmartPauseActive: false
        )
        XCTAssertEqual(returnedAfterBreak.nextState, .active)
        XCTAssertEqual(returnedAfterBreak.transition, .creditNaturalBreakAndReset)
    }

    func testFullscreenOrVideoSuppressesIdlePauseAndPreventsNaturalBreakCredit() {
        let settings = IdleNaturalBreakSettings(
            isEnabled: true,
            idlePauseThreshold: 120,
            naturalBreakDuration: 140
        )

        let fromActive = policy.evaluate(
            settings: settings,
            currentState: .active,
            idleSeconds: 300,
            isFullscreenOrVideoActive: true,
            isOtherSmartPauseActive: false
        )
        XCTAssertEqual(fromActive.nextState, .active)
        XCTAssertEqual(fromActive.transition, .none)

        let fromQualifiedIdle = policy.evaluate(
            settings: settings,
            currentState: .idlePaused(idleSeconds: 200, qualifiedForNaturalBreak: true),
            idleSeconds: 210,
            isFullscreenOrVideoActive: true,
            isOtherSmartPauseActive: false
        )
        XCTAssertEqual(fromQualifiedIdle.nextState, .active)
        XCTAssertEqual(fromQualifiedIdle.transition, .resumePausedCountdown)
    }

    func testTogglingOffWhileIdlePausedResumesWithoutCreditingNaturalBreak() {
        let disabledSettings = IdleNaturalBreakSettings(
            isEnabled: false,
            idlePauseThreshold: 120,
            naturalBreakDuration: 140
        )

        let result = policy.evaluate(
            settings: disabledSettings,
            currentState: .idlePaused(idleSeconds: 250, qualifiedForNaturalBreak: true),
            idleSeconds: 250,
            isFullscreenOrVideoActive: false,
            isOtherSmartPauseActive: false
        )

        XCTAssertEqual(result.nextState, .active)
        XCTAssertEqual(result.transition, .resumePausedCountdown)
    }

    func testSmartPausePolicyGivesHigherPriorityRulesPrecedenceOverUserIdle() {
        let idleSettings = IdleNaturalBreakSettings(isEnabled: true, idlePauseThreshold: 120)
        let idleState = IdleState.idlePaused(idleSeconds: 150, qualifiedForNaturalBreak: true)
        let apps = [
            RunningAppInfo(bundleIdentifier: "com.apple.Notes", localizedName: "Notes", isFrontmost: true)
        ]

        let idleOnly = smartPausePolicy.evaluate(
            meetingSettings: MeetingAutoPauseSettings(isEnabled: false),
            focusAppSettings: FocusAppPauseSettings(fullscreenPauseEnabled: false),
            idleSettings: idleSettings,
            idleState: idleState,
            isAudioInputActive: false,
            isFrontmostFullscreen: false,
            runningApps: apps
        )
        XCTAssertTrue(idleOnly.isPaused)
        XCTAssertEqual(idleOnly.reason, .userIdle)

        let withFullscreen = smartPausePolicy.evaluate(
            meetingSettings: MeetingAutoPauseSettings(isEnabled: false),
            focusAppSettings: FocusAppPauseSettings(fullscreenPauseEnabled: true),
            idleSettings: idleSettings,
            idleState: idleState,
            isAudioInputActive: false,
            isFrontmostFullscreen: true,
            runningApps: apps
        )
        XCTAssertEqual(withFullscreen.reason, .fullscreenApp(appName: "Notes"))

        let withMeeting = smartPausePolicy.evaluate(
            meetingSettings: MeetingAutoPauseSettings(isEnabled: true),
            focusAppSettings: FocusAppPauseSettings(fullscreenPauseEnabled: false),
            idleSettings: idleSettings,
            idleState: idleState,
            isAudioInputActive: true,
            isFrontmostFullscreen: false,
            runningApps: [RunningAppInfo(bundleIdentifier: "us.zoom.xos", localizedName: "zoom.us", isFrontmost: true)]
        )
        XCTAssertEqual(withMeeting.reason, .meetingOrCall(appName: "zoom.us"))
    }
}
