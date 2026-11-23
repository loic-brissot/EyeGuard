import XCTest
@testable import EyeGuardCore

final class SmartPausePolicyTests: XCTestCase {
    private let policy = MeetingAutoPausePolicy()

    func testDisabledPolicyNeverPausesEvenWhenMicAndMeetingAppActive() {
        let settings = MeetingAutoPauseSettings(isEnabled: false, excludedApps: [])
        let apps = [
            RunningAppInfo(bundleIdentifier: "us.zoom.xos", localizedName: "zoom.us", isFrontmost: true)
        ]

        let evaluation = policy.evaluate(
            settings: settings,
            isAudioInputActive: true,
            runningApps: apps
        )

        XCTAssertEqual(evaluation, .activeNone)
    }

    func testInactiveAudioInputNeverPausesEvenWhenMeetingAppRunning() {
        let settings = MeetingAutoPauseSettings(isEnabled: true, excludedApps: [])
        let apps = [
            RunningAppInfo(bundleIdentifier: "us.zoom.xos", localizedName: "zoom.us", isFrontmost: true),
            RunningAppInfo(bundleIdentifier: "com.tinyspeck.slackmacgap", localizedName: "Slack", isFrontmost: false)
        ]

        let evaluation = policy.evaluate(
            settings: settings,
            isAudioInputActive: false,
            runningApps: apps
        )

        XCTAssertFalse(evaluation.isPaused)
        XCTAssertNil(evaluation.reason)
    }

    func testActiveAudioInputWithKnownMeetingAppInBackgroundPauses() {
        let settings = MeetingAutoPauseSettings(isEnabled: true, excludedApps: [])
        let apps = [
            RunningAppInfo(bundleIdentifier: "com.apple.Notes", localizedName: "Notes", isFrontmost: true),
            RunningAppInfo(bundleIdentifier: "us.zoom.xos", localizedName: "zoom.us", isFrontmost: false)
        ]

        let evaluation = policy.evaluate(
            settings: settings,
            isAudioInputActive: true,
            runningApps: apps
        )

        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .meetingOrCall(appName: "zoom.us"))
        XCTAssertEqual(evaluation.matchedBundleID, "us.zoom.xos")
    }

    func testActiveAudioInputWithFrontmostBrowserPauses() {
        let apps = [
            RunningAppInfo(bundleIdentifier: "com.google.Chrome", localizedName: "Google Chrome", isFrontmost: true)
        ]

        let evaluation = policy.evaluate(
            isAudioInputActive: true,
            runningApps: apps,
            excludedApps: []
        )

        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .meetingOrCall(appName: "Google Chrome"))
    }

    func testExcludedFrontmostAppByBundleIDCaseInsensitivePreventsPause() {
        let apps = [
            RunningAppInfo(bundleIdentifier: "com.apple.VoiceMemos", localizedName: "Voice Memos", isFrontmost: true)
        ]

        let evaluation = policy.evaluate(
            isAudioInputActive: true,
            runningApps: apps,
            excludedApps: ["COM.APPLE.VOICEMEMOS"]
        )

        XCTAssertFalse(evaluation.isPaused)
        XCTAssertNil(evaluation.reason)
    }

    func testExcludedFrontmostAppByLocalizedNameCaseInsensitivePreventsPause() {
        let apps = [
            RunningAppInfo(bundleIdentifier: "com.apple.garageband10", localizedName: "GarageBand", isFrontmost: true)
        ]

        let evaluation = policy.evaluate(
            isAudioInputActive: true,
            runningApps: apps,
            excludedApps: ["  garageband  "]
        )

        XCTAssertFalse(evaluation.isPaused)
        XCTAssertNil(evaluation.reason)
    }

    func testExcludedBackgroundAppDoesNotPreventPauseForActiveCall() {
        let settings = MeetingAutoPauseSettings(
            isEnabled: true,
            excludedApps: ["com.apple.VoiceMemos"]
        )
        let apps = [
            RunningAppInfo(bundleIdentifier: "com.apple.VoiceMemos", localizedName: "Voice Memos", isFrontmost: false),
            RunningAppInfo(bundleIdentifier: "com.microsoft.teams2", localizedName: "Microsoft Teams", isFrontmost: true)
        ]

        let evaluation = policy.evaluate(
            settings: settings,
            isAudioInputActive: true,
            runningApps: apps
        )

        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .meetingOrCall(appName: "Microsoft Teams"))
    }

    func testExcludedKnownMeetingAppDoesNotTriggerPauseWhenFrontmost() {
        let apps = [
            RunningAppInfo(bundleIdentifier: "us.zoom.xos", localizedName: "zoom.us", isFrontmost: true)
        ]

        let evaluation = policy.evaluate(
            isAudioInputActive: true,
            runningApps: apps,
            excludedApps: ["us.zoom.xos"]
        )

        XCTAssertFalse(evaluation.isPaused)
    }

    func testActiveAudioInputWithNoRunningAppsPausesWithGenericReason() {
        let evaluation = policy.evaluate(
            isAudioInputActive: true,
            runningApps: [],
            excludedApps: []
        )

        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .meetingOrCall(appName: nil))
    }

    func testResumeTransitionWhenAudioInputEnds() {
        let apps = [
            RunningAppInfo(bundleIdentifier: "com.hnc.Discord", localizedName: "Discord", isFrontmost: true)
        ]

        let paused = policy.evaluate(isAudioInputActive: true, runningApps: apps, excludedApps: [])
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.reason, .meetingOrCall(appName: "Discord"))

        let resumed = policy.evaluate(isAudioInputActive: false, runningApps: apps, excludedApps: [])
        XCTAssertFalse(resumed.isPaused)
        XCTAssertNil(resumed.reason)
    }

    func testAddingAndRemovingExcludedAppsDeduplicatesCaseInsensitively() {
        var list: [String] = []
        list = MeetingAutoPausePolicy.addingExcludedApp("  com.apple.VoiceMemos ", to: list)
        list = MeetingAutoPausePolicy.addingExcludedApp("COM.APPLE.VOICEMEMOS", to: list)
        list = MeetingAutoPausePolicy.addingExcludedApp("", to: list)
        XCTAssertEqual(list, ["com.apple.VoiceMemos"])

        list = MeetingAutoPausePolicy.addingExcludedApp("GarageBand", to: list)
        XCTAssertEqual(list, ["com.apple.VoiceMemos", "GarageBand"])

        list = MeetingAutoPausePolicy.removingExcludedApp("garageband", from: list)
        XCTAssertEqual(list, ["com.apple.VoiceMemos"])
    }
}
