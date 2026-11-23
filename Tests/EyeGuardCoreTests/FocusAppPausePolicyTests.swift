import XCTest
@testable import EyeGuardCore

final class FocusAppPausePolicyTests: XCTestCase {
    private let focusPolicy = FocusAppPausePolicy()
    private let smartPausePolicy = SmartPausePolicy()

    // MARK: - Fullscreen Active Rule

    func testFullscreenRulePausesWhenEnabledAndFrontmostIsFullscreen() {
        let settings = FocusAppPauseSettings(fullscreenPauseEnabled: true, deepFocusApps: [])
        let safari = RunningAppInfo(bundleIdentifier: "com.apple.Safari", localizedName: "Safari", isFrontmost: true)
        let snapshot = FocusAppSnapshot(isFrontmostFullscreen: true, frontmostApp: safari, runningApps: [safari])

        let evaluation = focusPolicy.evaluate(settings: settings, snapshot: snapshot)

        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .fullscreenApp(appName: "Safari"))
        XCTAssertEqual(evaluation.matchedAppName, "Safari")
        XCTAssertEqual(evaluation.matchedBundleID, "com.apple.Safari")
        XCTAssertTrue(evaluation.isFullscreenOrVideoActive)
    }

    func testFullscreenRuleDoesNotPauseWhenDisabled() {
        let settings = FocusAppPauseSettings(fullscreenPauseEnabled: false, deepFocusApps: [])
        let vlc = RunningAppInfo(bundleIdentifier: "org.videolan.vlc", localizedName: "VLC", isFrontmost: true)
        let snapshot = FocusAppSnapshot(isFrontmostFullscreen: true, frontmostApp: vlc, runningApps: [vlc])

        let evaluation = focusPolicy.evaluate(settings: settings, snapshot: snapshot)

        XCTAssertEqual(evaluation, .activeNone)
        XCTAssertFalse(evaluation.isFullscreenOrVideoActive)
    }

    func testFullscreenRuleResumesWhenExitingFullscreen() {
        let settings = FocusAppPauseSettings(fullscreenPauseEnabled: true, deepFocusApps: [])
        let chrome = RunningAppInfo(bundleIdentifier: "com.google.Chrome", localizedName: "Google Chrome", isFrontmost: true)

        let paused = focusPolicy.evaluate(
            settings: settings,
            snapshot: FocusAppSnapshot(isFrontmostFullscreen: true, frontmostApp: chrome, runningApps: [chrome])
        )
        XCTAssertTrue(paused.isPaused)
        XCTAssertTrue(paused.isFullscreenOrVideoActive)

        let resumed = focusPolicy.evaluate(
            settings: settings,
            snapshot: FocusAppSnapshot(isFrontmostFullscreen: false, frontmostApp: chrome, runningApps: [chrome])
        )
        XCTAssertEqual(resumed, .activeNone)
        XCTAssertFalse(resumed.isFullscreenOrVideoActive)
    }

    // MARK: - Deep Focus App Rules

    func testDeepFocusWhenFrontmostPausesOnlyWhenAppIsFrontmost() {
        let xcodeRule = DeepFocusAppRule(identifier: "com.apple.dt.Xcode", displayName: "Xcode", triggerMode: .whenFrontmost)
        let settings = FocusAppPauseSettings(fullscreenPauseEnabled: true, deepFocusApps: [xcodeRule])
        let xcodeFront = RunningAppInfo(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", isFrontmost: true)
        let notesBack = RunningAppInfo(bundleIdentifier: "com.apple.Notes", localizedName: "Notes", isFrontmost: false)

        let paused = focusPolicy.evaluate(
            settings: settings,
            snapshot: FocusAppSnapshot(isFrontmostFullscreen: false, runningApps: [xcodeFront, notesBack])
        )
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.reason, .deepFocusApp(appName: "Xcode"))
        XCTAssertFalse(paused.isFullscreenOrVideoActive)

        // Switching away from Xcode resumes
        let xcodeBack = RunningAppInfo(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", isFrontmost: false)
        let notesFront = RunningAppInfo(bundleIdentifier: "com.apple.Notes", localizedName: "Notes", isFrontmost: true)
        let resumed = focusPolicy.evaluate(
            settings: settings,
            snapshot: FocusAppSnapshot(isFrontmostFullscreen: false, runningApps: [xcodeBack, notesFront])
        )
        XCTAssertEqual(resumed, .activeNone)
    }

    func testDeepFocusWhenOpenPausesInBackgroundAndResumesWhenQuit() {
        let figmaRule = DeepFocusAppRule(identifier: "com.figma.Desktop", displayName: "Figma", triggerMode: .whenOpen)
        let settings = FocusAppPauseSettings(fullscreenPauseEnabled: false, deepFocusApps: [figmaRule])

        let notesFront = RunningAppInfo(bundleIdentifier: "com.apple.Notes", localizedName: "Notes", isFrontmost: true)
        let figmaBack = RunningAppInfo(bundleIdentifier: "com.figma.Desktop", localizedName: "Figma", isFrontmost: false)

        let paused = focusPolicy.evaluate(
            settings: settings,
            snapshot: FocusAppSnapshot(isFrontmostFullscreen: false, runningApps: [notesFront, figmaBack])
        )
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.reason, .deepFocusApp(appName: "Figma"))
        XCTAssertEqual(paused.matchedBundleID, "com.figma.Desktop")

        // Quitting Figma resumes
        let resumed = focusPolicy.evaluate(
            settings: settings,
            snapshot: FocusAppSnapshot(isFrontmostFullscreen: false, runningApps: [notesFront])
        )
        XCTAssertEqual(resumed, .activeNone)
    }

    func testDeepFocusMatchesBundleIDAndLocalizedNameCaseInsensitively() {
        let byBundle = DeepFocusAppRule(identifier: "  COM.MICROSOFT.VSCODE ", triggerMode: .whenFrontmost)
        let byName = DeepFocusAppRule(identifier: "  blender ", triggerMode: .whenOpen)
        let settings = FocusAppPauseSettings(fullscreenPauseEnabled: false, deepFocusApps: [byBundle, byName])

        let vscode = RunningAppInfo(bundleIdentifier: "com.microsoft.VSCode", localizedName: "Visual Studio Code", isFrontmost: true)
        let evalBundle = focusPolicy.evaluate(
            settings: settings,
            snapshot: FocusAppSnapshot(isFrontmostFullscreen: false, runningApps: [vscode])
        )
        XCTAssertTrue(evalBundle.isPaused)
        XCTAssertEqual(evalBundle.reason, .deepFocusApp(appName: "Visual Studio Code"))

        let finder = RunningAppInfo(bundleIdentifier: "com.apple.finder", localizedName: "Finder", isFrontmost: true)
        let blender = RunningAppInfo(bundleIdentifier: "org.blenderfoundation.blender", localizedName: "Blender", isFrontmost: false)
        let evalName = focusPolicy.evaluate(
            settings: settings,
            snapshot: FocusAppSnapshot(isFrontmostFullscreen: false, runningApps: [finder, blender])
        )
        XCTAssertTrue(evalName.isPaused)
        XCTAssertEqual(evalName.reason, .deepFocusApp(appName: "Blender"))
    }

    // MARK: - Rule Evaluation Precedence & Resume Transitions

    func testPrecedenceMeetingOverFullscreenAndDeepFocus() {
        let meetingSettings = MeetingAutoPauseSettings(isEnabled: true, excludedApps: [])
        let focusSettings = FocusAppPauseSettings(
            fullscreenPauseEnabled: true,
            deepFocusApps: [
                DeepFocusAppRule(identifier: "us.zoom.xos", triggerMode: .whenFrontmost),
                DeepFocusAppRule(identifier: "com.apple.dt.Xcode", triggerMode: .whenOpen)
            ]
        )
        let zoomFront = RunningAppInfo(bundleIdentifier: "us.zoom.xos", localizedName: "zoom.us", isFrontmost: true)
        let xcodeBack = RunningAppInfo(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", isFrontmost: false)

        let duringMeeting = smartPausePolicy.evaluate(
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: true,
            isFrontmostFullscreen: true,
            runningApps: [zoomFront, xcodeBack]
        )
        XCTAssertEqual(duringMeeting.reason, .meetingOrCall(appName: "zoom.us"))
        XCTAssertFalse(duringMeeting.isFullscreenOrVideoActive)

        // Meeting ends while Zoom is still fullscreen -> falls back to Fullscreen Active
        let afterMeetingStillFullscreen = smartPausePolicy.evaluate(
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: false,
            isFrontmostFullscreen: true,
            runningApps: [zoomFront, xcodeBack]
        )
        XCTAssertEqual(afterMeetingStillFullscreen.reason, .fullscreenApp(appName: "zoom.us"))
        XCTAssertTrue(afterMeetingStillFullscreen.isFullscreenOrVideoActive)
    }

    func testPrecedenceFullscreenOverDeepFocusFrontmostAndOpen() {
        let meetingSettings = MeetingAutoPauseSettings(isEnabled: true, excludedApps: [])
        let focusSettings = FocusAppPauseSettings(
            fullscreenPauseEnabled: true,
            deepFocusApps: [
                DeepFocusAppRule(identifier: "com.apple.dt.Xcode", triggerMode: .whenFrontmost),
                DeepFocusAppRule(identifier: "com.figma.Desktop", triggerMode: .whenOpen)
            ]
        )
        let xcodeFront = RunningAppInfo(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", isFrontmost: true)
        let figmaBack = RunningAppInfo(bundleIdentifier: "com.figma.Desktop", localizedName: "Figma", isFrontmost: false)

        // Fullscreen wins over Deep Focus frontmost
        let fullscreenEval = smartPausePolicy.evaluate(
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: false,
            isFrontmostFullscreen: true,
            runningApps: [xcodeFront, figmaBack]
        )
        XCTAssertEqual(fullscreenEval.reason, .fullscreenApp(appName: "Xcode"))

        // Exit fullscreen -> Deep Focus frontmost (Xcode) wins over Deep Focus open (Figma)
        let frontmostDeepFocusEval = smartPausePolicy.evaluate(
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: false,
            isFrontmostFullscreen: false,
            runningApps: [xcodeFront, figmaBack]
        )
        XCTAssertEqual(frontmostDeepFocusEval.reason, .deepFocusApp(appName: "Xcode"))

        // Switch focus to Notes -> Deep Focus open (Figma) takes over
        let notesFront = RunningAppInfo(bundleIdentifier: "com.apple.Notes", localizedName: "Notes", isFrontmost: true)
        let xcodeBack = RunningAppInfo(bundleIdentifier: "com.apple.dt.Xcode", localizedName: "Xcode", isFrontmost: false)
        let openDeepFocusEval = smartPausePolicy.evaluate(
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: false,
            isFrontmostFullscreen: false,
            runningApps: [notesFront, xcodeBack, figmaBack]
        )
        XCTAssertEqual(openDeepFocusEval.reason, .deepFocusApp(appName: "Figma"))

        // Quit Figma -> resumes cleanly
        let resumedEval = smartPausePolicy.evaluate(
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: false,
            isFrontmostFullscreen: false,
            runningApps: [notesFront, xcodeBack]
        )
        XCTAssertEqual(resumedEval, .activeNone)
    }

    // MARK: - Rule List Management Helpers

    func testAddingUpdatingAndRemovingDeepFocusRules() {
        var rules: [DeepFocusAppRule] = []
        rules = FocusAppPauseSettings.addingRule(
            DeepFocusAppRule(identifier: "com.apple.dt.Xcode", displayName: "Xcode", triggerMode: .whenFrontmost),
            to: rules
        )
        // Duplicate case-insensitively updates mode instead of duplicating
        rules = FocusAppPauseSettings.addingRule(
            DeepFocusAppRule(identifier: "COM.APPLE.DT.XCODE", triggerMode: .whenOpen),
            to: rules
        )
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].triggerMode, .whenOpen)
        XCTAssertEqual(rules[0].displayName, "Xcode")

        rules = FocusAppPauseSettings.updatingTriggerMode(.whenFrontmost, for: "com.apple.dt.xcode", in: rules)
        XCTAssertEqual(rules[0].triggerMode, .whenFrontmost)

        rules = FocusAppPauseSettings.removingRule(identifier: "COM.APPLE.DT.XCODE", from: rules)
        XCTAssertTrue(rules.isEmpty)
    }
}
