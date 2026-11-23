import Foundation

/// Determines when a Deep Focus application rule triggers Smart Pause.
public enum DeepFocusTriggerMode: String, Codable, Equatable, Sendable, CaseIterable {
    case whenFrontmost
    case whenOpen

    public func toggled() -> DeepFocusTriggerMode {
        switch self {
        case .whenFrontmost:
            return .whenOpen
        case .whenOpen:
            return .whenFrontmost
        }
    }
}

/// User-configured rule for an application that triggers Deep Focus Smart Pause.
public struct DeepFocusAppRule: Codable, Equatable, Sendable {
    public let identifier: String
    public var displayName: String?
    public var triggerMode: DeepFocusTriggerMode

    public init(
        identifier: String,
        displayName: String? = nil,
        triggerMode: DeepFocusTriggerMode = .whenFrontmost
    ) {
        self.identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplay = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmedDisplay?.isEmpty == false) ? trimmedDisplay : nil
        self.triggerMode = triggerMode
    }

    public var effectiveDisplayName: String {
        displayName ?? identifier
    }

    public func matches(_ app: RunningAppInfo) -> Bool {
        let normalizedRule = MeetingAutoPausePolicy.normalizedIdentifier(identifier)
        guard !normalizedRule.isEmpty else { return false }

        let normalizedBundle = MeetingAutoPausePolicy.normalizedIdentifier(app.bundleIdentifier)
        if !normalizedBundle.isEmpty && normalizedBundle == normalizedRule {
            return true
        }

        let normalizedName = MeetingAutoPausePolicy.normalizedIdentifier(app.localizedName)
        if !normalizedName.isEmpty && normalizedName == normalizedRule {
            return true
        }

        return false
    }
}

/// Persisted configuration for Fullscreen and Deep Focus Smart Pause rules.
public struct FocusAppPauseSettings: Codable, Equatable, Sendable {
    public var fullscreenPauseEnabled: Bool
    public var deepFocusApps: [DeepFocusAppRule]

    public init(
        fullscreenPauseEnabled: Bool = true,
        deepFocusApps: [DeepFocusAppRule] = []
    ) {
        self.fullscreenPauseEnabled = fullscreenPauseEnabled
        self.deepFocusApps = deepFocusApps
    }

    public static func addingRule(_ rule: DeepFocusAppRule, to list: [DeepFocusAppRule]) -> [DeepFocusAppRule] {
        let normalizedNew = MeetingAutoPausePolicy.normalizedIdentifier(rule.identifier)
        guard !normalizedNew.isEmpty else { return list }

        if let existingIndex = list.firstIndex(where: {
            MeetingAutoPausePolicy.normalizedIdentifier($0.identifier) == normalizedNew
        }) {
            var updated = list
            updated[existingIndex].triggerMode = rule.triggerMode
            if let displayName = rule.displayName, !displayName.isEmpty {
                updated[existingIndex].displayName = displayName
            }
            return updated
        }

        return list + [rule]
    }

    public static func removingRule(identifier: String, from list: [DeepFocusAppRule]) -> [DeepFocusAppRule] {
        let normalized = MeetingAutoPausePolicy.normalizedIdentifier(identifier)
        return list.filter { MeetingAutoPausePolicy.normalizedIdentifier($0.identifier) != normalized }
    }

    public static func updatingTriggerMode(
        _ triggerMode: DeepFocusTriggerMode,
        for identifier: String,
        in list: [DeepFocusAppRule]
    ) -> [DeepFocusAppRule] {
        let normalized = MeetingAutoPausePolicy.normalizedIdentifier(identifier)
        return list.map { rule in
            guard MeetingAutoPausePolicy.normalizedIdentifier(rule.identifier) == normalized else {
                return rule
            }
            var updated = rule
            updated.triggerMode = triggerMode
            return updated
        }
    }

    public static func containsApp(_ app: RunningAppInfo, in list: [DeepFocusAppRule]) -> Bool {
        list.contains { $0.matches(app) }
    }
}

/// Platform-independent snapshot of fullscreen state and running/frontmost apps.
public struct FocusAppSnapshot: Equatable, Sendable {
    public let isFrontmostFullscreen: Bool
    public let frontmostApp: RunningAppInfo?
    public let runningApps: [RunningAppInfo]

    public init(
        isFrontmostFullscreen: Bool,
        frontmostApp: RunningAppInfo? = nil,
        runningApps: [RunningAppInfo] = []
    ) {
        self.isFrontmostFullscreen = isFrontmostFullscreen
        self.frontmostApp = frontmostApp ?? runningApps.first(where: { $0.isFrontmost })
        self.runningApps = runningApps
    }
}

/// Pure, deterministic policy evaluating Fullscreen Active and Deep Focus app rules.
///
/// Precedence:
/// 1. Fullscreen Active (when `fullscreenPauseEnabled` is true and frontmost app is fullscreen)
/// 2. Deep Focus app matching frontmost app (`whenFrontmost` or `whenOpen`)
/// 3. Deep Focus app matching any running app (`whenOpen`)
public struct FocusAppPausePolicy: Sendable {
    public init() {}

    public func evaluate(
        settings: FocusAppPauseSettings,
        snapshot: FocusAppSnapshot
    ) -> SmartPauseEvaluation {
        let frontmost = snapshot.frontmostApp ?? snapshot.runningApps.first(where: { $0.isFrontmost })

        // 1. Fullscreen Active rule
        if settings.fullscreenPauseEnabled && snapshot.isFrontmostFullscreen {
            let appName = frontmost?.localizedName.isEmpty == false ? frontmost?.localizedName : nil
            let bundleID = frontmost?.bundleIdentifier.isEmpty == false ? frontmost?.bundleIdentifier : nil
            return SmartPauseEvaluation(
                isPaused: true,
                reason: .fullscreenApp(appName: appName),
                matchedAppName: appName,
                matchedBundleID: bundleID
            )
        }

        // 2. Deep Focus rule matching frontmost app (both .whenFrontmost and .whenOpen qualify)
        if let frontmost = frontmost,
           settings.deepFocusApps.contains(where: { $0.matches(frontmost) }) {
            let appName = frontmost.localizedName.isEmpty ? nil : frontmost.localizedName
            let bundleID = frontmost.bundleIdentifier.isEmpty ? nil : frontmost.bundleIdentifier
            return SmartPauseEvaluation(
                isPaused: true,
                reason: .deepFocusApp(appName: appName),
                matchedAppName: appName,
                matchedBundleID: bundleID
            )
        }

        // 3. Deep Focus rule matching any open background app (.whenOpen only)
        let openRules = settings.deepFocusApps.filter { $0.triggerMode == .whenOpen }
        if !openRules.isEmpty {
            for rule in openRules {
                if let matchedApp = snapshot.runningApps.first(where: { rule.matches($0) }) {
                    let appName = matchedApp.localizedName.isEmpty ? rule.effectiveDisplayName : matchedApp.localizedName
                    let bundleID = matchedApp.bundleIdentifier.isEmpty ? nil : matchedApp.bundleIdentifier
                    return SmartPauseEvaluation(
                        isPaused: true,
                        reason: .deepFocusApp(appName: appName),
                        matchedAppName: appName,
                        matchedBundleID: bundleID
                    )
                }
            }
        }

        return .activeNone
    }
}
