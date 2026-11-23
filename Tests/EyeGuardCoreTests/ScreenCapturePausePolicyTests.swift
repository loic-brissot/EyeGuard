import XCTest
@testable import EyeGuardCore

final class ScreenCapturePausePolicyTests: XCTestCase {
    private let policy = ScreenCapturePausePolicy()
    private let smartPausePolicy = SmartPausePolicy()

    // MARK: - Active Capture Detection

    func testActiveScreenSharingOrRecordingPausesBreaksWithSource() {
        let settings = ScreenCaptureSettings(isEnabled: true)
        let snapshot = ScreenCaptureSnapshot(
            isScreenSharingOrRecordingActive: true,
            activeSourceName: "Screen Recording",
            permissionState: .granted
        )

        let evaluation = policy.evaluate(settings: settings, snapshot: snapshot)

        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .screenRecordingOrSharing(source: "Screen Recording"))
        XCTAssertEqual(evaluation.matchedAppName, "Screen Recording")
        XCTAssertNil(evaluation.matchedBundleID)
        XCTAssertFalse(evaluation.isFullscreenOrVideoActive)
    }

    func testActiveScreenSharingWithoutSourcePausesWithNilSource() {
        let settings = ScreenCaptureSettings(isEnabled: true)
        let snapshot = ScreenCaptureSnapshot(
            isScreenSharingOrRecordingActive: true,
            activeSourceName: "   ",
            permissionState: .granted
        )

        let evaluation = policy.evaluate(settings: settings, snapshot: snapshot)

        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .screenRecordingOrSharing(source: nil))
        XCTAssertNil(evaluation.matchedAppName)
    }

    // MARK: - Disabled Setting

    func testDisabledSettingNeverPausesEvenWhenCaptureIsActive() {
        let settings = ScreenCaptureSettings(isEnabled: false)
        let snapshot = ScreenCaptureSnapshot(
            isScreenSharingOrRecordingActive: true,
            activeSourceName: "OBS",
            permissionState: .granted
        )

        let evaluation = policy.evaluate(settings: settings, snapshot: snapshot)

        XCTAssertEqual(evaluation, .activeNone)
    }

    // MARK: - Graceful Degradation Without Permission

    func testDeniedOrUnknownPermissionWithoutActiveSignalDoesNotFalsePause() {
        let settings = ScreenCaptureSettings(isEnabled: true)

        let deniedSnapshot = ScreenCaptureSnapshot(
            isScreenSharingOrRecordingActive: false,
            activeSourceName: nil,
            permissionState: .denied
        )
        XCTAssertEqual(policy.evaluate(settings: settings, snapshot: deniedSnapshot), .activeNone)

        let unknownSnapshot = ScreenCaptureSnapshot(
            isScreenSharingOrRecordingActive: false,
            activeSourceName: nil,
            permissionState: .unknown
        )
        XCTAssertEqual(policy.evaluate(settings: settings, snapshot: unknownSnapshot), .activeNone)
    }

    func testDeniedPermissionStillPausesWhenNonPermissionSignalDetectsCapture() {
        let settings = ScreenCaptureSettings(isEnabled: true)
        let snapshot = ScreenCaptureSnapshot(
            isScreenSharingOrRecordingActive: true,
            activeSourceName: "Screen Sharing",
            permissionState: .denied
        )

        let evaluation = policy.evaluate(settings: settings, snapshot: snapshot)

        XCTAssertTrue(evaluation.isPaused)
        XCTAssertEqual(evaluation.reason, .screenRecordingOrSharing(source: "Screen Sharing"))
        XCTAssertEqual(evaluation.matchedAppName, "Screen Sharing")
    }

    // MARK: - Unified SmartPausePolicy Precedence & Resume

    func testPrecedenceScreenCaptureOverMeetingFullscreenAndDeepFocus() {
        let screenCaptureSettings = ScreenCaptureSettings(isEnabled: true)
        let meetingSettings = MeetingAutoPauseSettings(isEnabled: true, excludedApps: [])
        let focusSettings = FocusAppPauseSettings(
            fullscreenPauseEnabled: true,
            deepFocusApps: [
                DeepFocusAppRule(identifier: "com.apple.dt.Xcode", triggerMode: .whenFrontmost)
            ]
        )
        let zoom = RunningAppInfo(bundleIdentifier: "us.zoom.xos", localizedName: "zoom.us", isFrontmost: true)

        let duringScreenShare = smartPausePolicy.evaluate(
            screenCaptureSettings: screenCaptureSettings,
            screenCaptureSnapshot: ScreenCaptureSnapshot(
                isScreenSharingOrRecordingActive: true,
                activeSourceName: "zoom.us",
                permissionState: .granted
            ),
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: true,
            isFrontmostFullscreen: true,
            runningApps: [zoom]
        )
        XCTAssertEqual(duringScreenShare.reason, .screenRecordingOrSharing(source: "zoom.us"))

        // Screen share stops while meeting is still active -> falls back to meeting/call
        let afterScreenShareStops = smartPausePolicy.evaluate(
            screenCaptureSettings: screenCaptureSettings,
            screenCaptureSnapshot: .inactive,
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: true,
            isFrontmostFullscreen: true,
            runningApps: [zoom]
        )
        XCTAssertEqual(afterScreenShareStops.reason, .meetingOrCall(appName: "zoom.us"))
    }

    func testCleanResumeWhenCaptureStops() {
        let screenCaptureSettings = ScreenCaptureSettings(isEnabled: true)
        let meetingSettings = MeetingAutoPauseSettings(isEnabled: true, excludedApps: [])
        let focusSettings = FocusAppPauseSettings(fullscreenPauseEnabled: true, deepFocusApps: [])
        let finder = RunningAppInfo(bundleIdentifier: "com.apple.finder", localizedName: "Finder", isFrontmost: true)

        let paused = smartPausePolicy.evaluate(
            screenCaptureSettings: screenCaptureSettings,
            screenCaptureSnapshot: ScreenCaptureSnapshot(
                isScreenSharingOrRecordingActive: true,
                activeSourceName: "Screen Recording",
                permissionState: .denied
            ),
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: false,
            isFrontmostFullscreen: false,
            runningApps: [finder]
        )
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.reason, .screenRecordingOrSharing(source: "Screen Recording"))

        let resumed = smartPausePolicy.evaluate(
            screenCaptureSettings: screenCaptureSettings,
            screenCaptureSnapshot: ScreenCaptureSnapshot(
                isScreenSharingOrRecordingActive: false,
                activeSourceName: nil,
                permissionState: .denied
            ),
            meetingSettings: meetingSettings,
            focusAppSettings: focusSettings,
            isAudioInputActive: false,
            isFrontmostFullscreen: false,
            runningApps: [finder]
        )
        XCTAssertEqual(resumed, .activeNone)
    }
}
