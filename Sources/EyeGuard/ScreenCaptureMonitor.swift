import Cocoa
import CoreGraphics
import EyeGuardCore

protocol ScreenCaptureSignalProviding {
    func currentSnapshot() -> ScreenCaptureSnapshot
}

/// Combines non-intrusive macOS signals to detect active screen sharing or screen recording
/// without prompting for Screen Recording permission on startup.
struct SystemScreenCaptureSignalProvider: ScreenCaptureSignalProviding {
    struct WindowInfo: Equatable {
        let ownerPID: pid_t
        let ownerName: String
        let windowName: String?
        let layer: Int
    }

    private let selfPID: pid_t
    private let checkPermission: () -> ScreenCapturePermissionState
    private let fetchWindowList: () -> [WindowInfo]
    private let fetchRunningApps: () -> [RunningAppInfo]
    private let checkDisplayMirroring: () -> Bool

    init(
        selfPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        checkPermission: @escaping () -> ScreenCapturePermissionState = Self.defaultPermissionCheck,
        fetchWindowList: @escaping () -> [WindowInfo] = Self.defaultFetchWindowList,
        fetchRunningApps: @escaping () -> [RunningAppInfo] = MeetingCallMonitor.collectRunningApps,
        checkDisplayMirroring: @escaping () -> Bool = Self.defaultIsDisplayMirrored
    ) {
        self.selfPID = selfPID
        self.checkPermission = checkPermission
        self.fetchWindowList = fetchWindowList
        self.fetchRunningApps = fetchRunningApps
        self.checkDisplayMirroring = checkDisplayMirroring
    }

    func currentSnapshot() -> ScreenCaptureSnapshot {
        let permissionState = checkPermission()

        // 1. Window-server / Control Center indicators (owner names work even without permission;
        //    window titles provide extra fidelity when permission is .granted).
        if let windowSource = detectFromWindowList(fetchWindowList(), permissionState: permissionState) {
            return ScreenCaptureSnapshot(
                isScreenSharingOrRecordingActive: true,
                activeSourceName: windowSource,
                permissionState: permissionState
            )
        }

        // 2. Active macOS system capture / screen-sharing processes (no permission required).
        if let processSource = detectFromRunningApps(fetchRunningApps()) {
            return ScreenCaptureSnapshot(
                isScreenSharingOrRecordingActive: true,
                activeSourceName: processSource,
                permissionState: permissionState
            )
        }

        // 3. Display mirroring / AirPlay mirror set (no permission required).
        if checkDisplayMirroring() {
            return ScreenCaptureSnapshot(
                isScreenSharingOrRecordingActive: true,
                activeSourceName: "Display Mirroring",
                permissionState: permissionState
            )
        }

        return ScreenCaptureSnapshot(
            isScreenSharingOrRecordingActive: false,
            activeSourceName: nil,
            permissionState: permissionState
        )
    }

    private func detectFromWindowList(
        _ windows: [WindowInfo],
        permissionState: ScreenCapturePermissionState
    ) -> String? {
        for window in windows {
            guard window.ownerPID != selfPID else { continue }

            let ownerLower = window.ownerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !ownerLower.isEmpty else { continue }

            // Dedicated macOS capture/sharing window owners (reliable regardless of TCC state)
            if ownerLower == "screencaptureui" || ownerLower == "screencapture" {
                return "Screen Recording"
            }
            if ownerLower == "screensharingagent" || ownerLower == "screensharingd" || ownerLower == "screen sharing" {
                return "Screen Sharing"
            }
            if ownerLower == "replayd" {
                return "Screen Recording"
            }
            if ownerLower == "airplayuiagent" {
                return "AirPlay"
            }

            // When Screen Recording permission is granted, window titles are readable for Control Center
            // and third-party capture/meeting indicator windows.
            guard permissionState == .granted,
                  let rawTitle = window.windowName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawTitle.isEmpty else {
                continue
            }

            let titleLower = rawTitle.lowercased()
            if ownerLower == "controlcenter" || ownerLower == "control center" {
                if titleLower.contains("screen recording") || titleLower.contains("recording") {
                    return "Screen Recording"
                }
                if titleLower.contains("screen sharing") {
                    return "Screen Sharing"
                }
                if titleLower.contains("screen mirroring") || titleLower.contains("airplay") {
                    return "Screen Mirroring"
                }
            }

            if Self.isKnownThirdPartyCaptureIndicator(ownerLower: ownerLower, titleLower: titleLower) {
                return window.ownerName
            }
        }
        return nil
    }

    private func detectFromRunningApps(_ apps: [RunningAppInfo]) -> String? {
        for app in apps {
            let bundleLower = app.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let nameLower = app.localizedName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            if bundleLower == "com.apple.screencaptureui" || nameLower == "screencaptureui" {
                return "Screen Recording"
            }
            if bundleLower == "com.apple.screensharing"
                || bundleLower == "com.apple.screensharing.agent"
                || nameLower == "screensharingagent" {
                return "Screen Sharing"
            }
            if bundleLower == "com.apple.airplayuiagent" || nameLower == "airplayuiagent" {
                return "AirPlay"
            }
        }
        return nil
    }

    private static func isKnownThirdPartyCaptureIndicator(ownerLower: String, titleLower: String) -> Bool {
        let captureTitleHints = [
            "screen recording",
            "screen sharing",
            "is sharing your screen",
            "you are screen sharing",
            "sharing your screen"
        ]
        guard captureTitleHints.contains(where: { titleLower.contains($0) }) else {
            return false
        }

        let knownOwners = [
            "zoom.us",
            "zoom",
            "microsoft teams",
            "teams",
            "loom",
            "obs",
            "obs studio",
            "quicktime player"
        ]
        return knownOwners.contains(where: { ownerLower.contains($0) })
    }

    static func defaultPermissionCheck() -> ScreenCapturePermissionState {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    static func defaultFetchWindowList() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = info[kCGWindowOwnerName as String] as? String else {
                return nil
            }
            let windowName = info[kCGWindowName as String] as? String
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            return WindowInfo(
                ownerPID: ownerPID,
                ownerName: ownerName,
                windowName: windowName,
                layer: layer
            )
        }
    }

    static func defaultIsDisplayMirrored() -> Bool {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else {
            return false
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success else {
            return false
        }

        return displays.prefix(Int(displayCount)).contains { displayID in
            CGDisplayIsInMirrorSet(displayID) != 0
        }
    }
}

/// Monitors active macOS screen sharing / screen recording sessions and emits snapshots.
final class ScreenCaptureMonitor {
    var onUpdate: ((ScreenCaptureSnapshot) -> Void)?

    private let pollInterval: TimeInterval
    private let signalProvider: ScreenCaptureSignalProviding
    private var pollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []
    private(set) var lastSnapshot: ScreenCaptureSnapshot = .inactive

    init(
        pollInterval: TimeInterval = 2.0,
        signalProvider: ScreenCaptureSignalProviding = SystemScreenCaptureSignalProvider()
    ) {
        self.pollInterval = pollInterval
        self.signalProvider = signalProvider
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        registerObservers()
        pollNow()
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let defaultCenter = NotificationCenter.default
        for observer in appObservers {
            defaultCenter.removeObserver(observer)
        }
        appObservers.removeAll()
    }

    func pollNow() {
        let snapshot = currentSnapshot()
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    func currentSnapshot() -> ScreenCaptureSnapshot {
        signalProvider.currentSnapshot()
    }

    private func registerObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let workspaceNames: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification
        ]
        workspaceObservers = workspaceNames.map { name in
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.pollNow()
            }
        }

        let screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.pollNow()
        }
        appObservers = [screenObserver]
    }
}
