import Foundation

/// Extensible reason describing why Smart Pause is currently holding break transitions.
public enum SmartPauseReason: Equatable, Sendable {
    case screenRecordingOrSharing(source: String?)
    case meetingOrCall(appName: String?)
    case calendarEvent(title: String?)
    case fullscreenApp(appName: String?)
    case deepFocusApp(appName: String?)
    case typingOrDragging

    /// Indicates whether the active pause reason is a fullscreen or video experience (used by TASK-9 soft-break handling).
    public var isFullscreenOrVideo: Bool {
        if case .fullscreenApp = self {
            return true
        }
        return false
    }
}

/// Lightweight, platform-independent snapshot of a running application for Smart Pause evaluation.
public struct RunningAppInfo: Equatable, Sendable {
    public let bundleIdentifier: String
    public let localizedName: String
    public let isFrontmost: Bool

    public init(bundleIdentifier: String, localizedName: String, isFrontmost: Bool = false) {
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.isFrontmost = isFrontmost
    }
}

/// Persisted configuration for meeting / call auto-pause.
public struct MeetingAutoPauseSettings: Equatable, Codable, Sendable {
    public var isEnabled: Bool
    public var excludedApps: [String]

    public init(isEnabled: Bool = true, excludedApps: [String] = []) {
        self.isEnabled = isEnabled
        self.excludedApps = excludedApps
    }
}

/// Result of evaluating Smart Pause rules at a point in time.
public struct SmartPauseEvaluation: Equatable, Sendable {
    public let isPaused: Bool
    public let reason: SmartPauseReason?
    public let matchedAppName: String?
    public let matchedBundleID: String?

    public init(
        isPaused: Bool,
        reason: SmartPauseReason?,
        matchedAppName: String?,
        matchedBundleID: String?
    ) {
        self.isPaused = isPaused
        self.reason = reason
        self.matchedAppName = matchedAppName
        self.matchedBundleID = matchedBundleID
    }

    public static let activeNone = SmartPauseEvaluation(
        isPaused: false,
        reason: nil,
        matchedAppName: nil,
        matchedBundleID: nil
    )

    /// Indicates whether fullscreen/video Smart Pause is currently active.
    public var isFullscreenOrVideoActive: Bool {
        isPaused && (reason?.isFullscreenOrVideo ?? false)
    }
}

/// Unified Smart Pause policy evaluating all active auto-pause rules in deterministic precedence:
/// 1. Active screen recording / sharing (if enabled)
/// 2. Active meeting/call (audio input + meeting app rules)
/// 3. Active busy calendar event (if enabled and authorized)
/// 4. Fullscreen active app (if enabled)
/// 5. Deep Focus app (frontmost, then open background `.whenOpen`)
public struct SmartPausePolicy: Sendable {
    private let screenCapturePolicy = ScreenCapturePausePolicy()
    private let meetingPolicy = MeetingAutoPausePolicy()
    private let calendarPolicy = CalendarPausePolicy()
    private let focusAppPolicy = FocusAppPausePolicy()

    public init() {}

    public func evaluate(
        screenCaptureSettings: ScreenCaptureSettings = ScreenCaptureSettings(),
        screenCaptureSnapshot: ScreenCaptureSnapshot = .inactive,
        meetingSettings: MeetingAutoPauseSettings,
        calendarSettings: CalendarPauseSettings = CalendarPauseSettings(),
        calendarSnapshot: CalendarSnapshot = .empty,
        focusAppSettings: FocusAppPauseSettings,
        isAudioInputActive: Bool,
        isFrontmostFullscreen: Bool,
        runningApps: [RunningAppInfo],
        now: Date = Date()
    ) -> SmartPauseEvaluation {
        let screenCaptureEvaluation = screenCapturePolicy.evaluate(
            settings: screenCaptureSettings,
            snapshot: screenCaptureSnapshot
        )
        if screenCaptureEvaluation.isPaused {
            return screenCaptureEvaluation
        }

        let meetingEvaluation = meetingPolicy.evaluate(
            settings: meetingSettings,
            isAudioInputActive: isAudioInputActive,
            runningApps: runningApps
        )
        if meetingEvaluation.isPaused {
            return meetingEvaluation
        }

        let calendarEvaluation = calendarPolicy.evaluate(
            settings: calendarSettings,
            snapshot: calendarSnapshot,
            now: now
        )
        if calendarEvaluation.isPaused {
            return calendarEvaluation
        }

        let focusSnapshot = FocusAppSnapshot(
            isFrontmostFullscreen: isFrontmostFullscreen,
            frontmostApp: runningApps.first(where: { $0.isFrontmost }),
            runningApps: runningApps
        )
        return focusAppPolicy.evaluate(
            settings: focusAppSettings,
            snapshot: focusSnapshot
        )
    }
}

/// Pure, deterministic policy for automatically pausing breaks during active meetings/calls.
public struct MeetingAutoPausePolicy: Sendable {
    public static let knownMeetingBundleIDs: Set<String> = [
        "us.zoom.xos",
        "us.zoom.ringcentral",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",
        "com.hnc.discord",
        "com.apple.facetime",
        "com.cisco.webexmeetingsapp",
        "cisco-systems.spark",
        "com.webex.meetingmanager",
        "com.skype.skype",
        "com.loom.desktop",
        "com.around.desktop",
        "com.tuple.app",
        "com.gather.gather",
        "com.google.chrome.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
        "com.brave.browser.app.kjgfgldnnfoeklkmfkjfagphfepbbdan",
        "com.microsoft.edgemac.app.kjgfgldnnfoeklkmfkjfagphfepbbdan"
    ]

    public static let knownMeetingAppNames: Set<String> = [
        "zoom.us",
        "zoom",
        "microsoft teams",
        "teams",
        "slack",
        "discord",
        "facetime",
        "webex",
        "cisco webex meetings",
        "google meet",
        "skype",
        "tuple"
    ]

    public init() {}

    public static func normalizedIdentifier(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func normalizedExcludedSet(from excludedApps: [String]) -> Set<String> {
        Set(excludedApps.map(normalizedIdentifier).filter { !$0.isEmpty })
    }

    public static func addingExcludedApp(_ identifier: String, to list: [String]) -> [String] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedIdentifier(trimmed)
        guard !normalized.isEmpty else { return list }
        if list.contains(where: { normalizedIdentifier($0) == normalized }) {
            return list
        }
        return list + [trimmed]
    }

    public static func removingExcludedApp(_ identifier: String, from list: [String]) -> [String] {
        let normalized = normalizedIdentifier(identifier)
        return list.filter { normalizedIdentifier($0) != normalized }
    }

    public static func isExcluded(_ app: RunningAppInfo, excludedSet: Set<String>) -> Bool {
        let bundle = normalizedIdentifier(app.bundleIdentifier)
        if !bundle.isEmpty && excludedSet.contains(bundle) {
            return true
        }
        let name = normalizedIdentifier(app.localizedName)
        if !name.isEmpty && excludedSet.contains(name) {
            return true
        }
        return false
    }

    public static func isKnownMeetingApp(_ app: RunningAppInfo) -> Bool {
        let bundle = normalizedIdentifier(app.bundleIdentifier)
        if !bundle.isEmpty && knownMeetingBundleIDs.contains(bundle) {
            return true
        }
        let name = normalizedIdentifier(app.localizedName)
        if !name.isEmpty && knownMeetingAppNames.contains(name) {
            return true
        }
        return false
    }

    public func evaluate(
        settings: MeetingAutoPauseSettings,
        isAudioInputActive: Bool,
        runningApps: [RunningAppInfo]
    ) -> SmartPauseEvaluation {
        evaluate(
            isEnabled: settings.isEnabled,
            isAudioInputActive: isAudioInputActive,
            runningApps: runningApps,
            excludedApps: Self.normalizedExcludedSet(from: settings.excludedApps)
        )
    }

    public func evaluate(
        isEnabled: Bool = true,
        isAudioInputActive: Bool,
        runningApps: [RunningAppInfo],
        excludedApps: Set<String>
    ) -> SmartPauseEvaluation {
        guard isEnabled, isAudioInputActive else {
            return .activeNone
        }

        let normalizedExcluded = Set(excludedApps.map(Self.normalizedIdentifier).filter { !$0.isEmpty })

        // 1. If any non-excluded known meeting/call app is running while audio input is active,
        // pause breaks even if the user switched focus to another app (e.g. taking notes).
        let activeMeetingApps = runningApps.filter {
            Self.isKnownMeetingApp($0) && !Self.isExcluded($0, excludedSet: normalizedExcluded)
        }
        if let meetingApp = activeMeetingApps.first(where: { $0.isFrontmost }) ?? activeMeetingApps.first {
            let appName = meetingApp.localizedName.isEmpty ? nil : meetingApp.localizedName
            return SmartPauseEvaluation(
                isPaused: true,
                reason: .meetingOrCall(appName: appName),
                matchedAppName: appName,
                matchedBundleID: meetingApp.bundleIdentifier.isEmpty ? nil : meetingApp.bundleIdentifier
            )
        }

        // 2. Otherwise check the frontmost application. If the user explicitly excluded it
        // (e.g. Voice Memos, GarageBand, Dictation), do not pause breaks.
        if let frontmost = runningApps.first(where: { $0.isFrontmost }) {
            if Self.isExcluded(frontmost, excludedSet: normalizedExcluded) {
                return .activeNone
            }
            let appName = frontmost.localizedName.isEmpty ? nil : frontmost.localizedName
            return SmartPauseEvaluation(
                isPaused: true,
                reason: .meetingOrCall(appName: appName),
                matchedAppName: appName,
                matchedBundleID: frontmost.bundleIdentifier.isEmpty ? nil : frontmost.bundleIdentifier
            )
        }

        // 3. No frontmost app info: if all running apps are excluded, do not pause;
        // otherwise treat active microphone as an active call/meeting.
        if !runningApps.isEmpty && runningApps.allSatisfy({ Self.isExcluded($0, excludedSet: normalizedExcluded) }) {
            return .activeNone
        }

        return SmartPauseEvaluation(
            isPaused: true,
            reason: .meetingOrCall(appName: nil),
            matchedAppName: nil,
            matchedBundleID: nil
        )
    }
}
