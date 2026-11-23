import Foundation

/// Persisted configuration for Screen Recording / Sharing auto-pause.
public struct ScreenCaptureSettings: Equatable, Codable, Sendable {
    public var isEnabled: Bool

    public init(isEnabled: Bool = true) {
        self.isEnabled = isEnabled
    }
}

/// Permission state for macOS Screen Recording access without prompting the user.
public enum ScreenCapturePermissionState: String, Equatable, Codable, Sendable {
    case granted
    case denied
    case unknown
}

/// Platform-independent snapshot of active screen recording / sharing state.
public struct ScreenCaptureSnapshot: Equatable, Sendable {
    public let isScreenSharingOrRecordingActive: Bool
    public let activeSourceName: String?
    public let permissionState: ScreenCapturePermissionState

    public init(
        isScreenSharingOrRecordingActive: Bool = false,
        activeSourceName: String? = nil,
        permissionState: ScreenCapturePermissionState = .unknown
    ) {
        self.isScreenSharingOrRecordingActive = isScreenSharingOrRecordingActive
        let trimmedSource = activeSourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.activeSourceName = (trimmedSource?.isEmpty == false) ? trimmedSource : nil
        self.permissionState = permissionState
    }

    public static let inactive = ScreenCaptureSnapshot(
        isScreenSharingOrRecordingActive: false,
        activeSourceName: nil,
        permissionState: .unknown
    )
}

/// Pure, deterministic policy for pausing breaks during active screen sharing or screen recording.
///
/// Degrades gracefully when macOS Screen Recording permission is `.denied` or `.unknown`:
/// - Never crashes or false-pauses when permission-gated signals are unavailable.
/// - Still pauses if a non-permission signal (e.g. system capture agent or display mirroring) detects active capture.
public struct ScreenCapturePausePolicy: Sendable {
    public init() {}

    public func evaluate(
        settings: ScreenCaptureSettings,
        snapshot: ScreenCaptureSnapshot
    ) -> SmartPauseEvaluation {
        guard settings.isEnabled, snapshot.isScreenSharingOrRecordingActive else {
            return .activeNone
        }

        return SmartPauseEvaluation(
            isPaused: true,
            reason: .screenRecordingOrSharing(source: snapshot.activeSourceName),
            matchedAppName: snapshot.activeSourceName,
            matchedBundleID: nil
        )
    }
}
