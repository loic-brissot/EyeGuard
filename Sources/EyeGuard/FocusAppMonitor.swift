import Cocoa
import CoreGraphics
import EyeGuardCore

/// Monitors frontmost fullscreen windows (via CoreGraphics without Accessibility permissions)
/// and running/frontmost applications for Fullscreen Active and Deep Focus Smart Pause rules.
final class FocusAppMonitor {
    var onUpdate: ((FocusAppSnapshot) -> Void)?

    private let pollInterval: TimeInterval
    private var pollTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private(set) var lastSnapshot = FocusAppSnapshot(
        isFrontmostFullscreen: false,
        frontmostApp: nil,
        runningApps: []
    )

    init(pollInterval: TimeInterval = 2.0) {
        self.pollInterval = pollInterval
    }

    deinit {
        stop()
    }

    func start() {
        stop()
        registerWorkspaceObservers()
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
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    func pollNow() {
        let snapshot = currentSnapshot()
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    func currentSnapshot() -> FocusAppSnapshot {
        let runningApps = MeetingCallMonitor.collectRunningApps()
        let frontmostApp = runningApps.first(where: { $0.isFrontmost })
        let isFullscreen = Self.isFrontmostApplicationFullscreen()
        return FocusAppSnapshot(
            isFrontmostFullscreen: isFullscreen,
            frontmostApp: frontmostApp,
            runningApps: runningApps
        )
    }

    private func registerWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        let notifications: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        workspaceObservers = notifications.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.pollNow()
            }
        }
    }

    /// Detects whether the current frontmost application has an on-screen normal-layer window
    /// covering the full frame of any attached display. Uses CoreGraphics only (no Accessibility prompt).
    static func isFrontmostApplicationFullscreen() -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.activationPolicy != .prohibited else {
            return false
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        if frontmost.processIdentifier == selfPID {
            return false
        }

        if let selfBundleID = Bundle.main.bundleIdentifier?.lowercased(),
           let frontBundle = frontmost.bundleIdentifier?.lowercased(),
           frontBundle == selfBundleID {
            return false
        }

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }

        // Convert NSScreen Cocoa frames (bottom-left origin) to Quartz global coordinates (top-left origin).
        let primaryScreenHeight = screens.first(where: { $0.frame.origin == .zero })?.frame.height ?? screens[0].frame.height
        let quartzScreenFrames = screens.map { screen -> CGRect in
            let frame = screen.frame
            return CGRect(
                x: frame.origin.x,
                y: primaryScreenHeight - frame.origin.y - frame.height,
                width: frame.width,
                height: frame.height
            )
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let frontPID = frontmost.processIdentifier
        return windowInfoList.contains { info in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == frontPID else {
                return false
            }

            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { return false }

            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0 else { return false }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let windowRect = CGRect(dictionaryRepresentation: boundsDict) else {
                return false
            }

            return quartzScreenFrames.contains { screenRect in
                abs(windowRect.origin.x - screenRect.origin.x) <= 2 &&
                abs(windowRect.origin.y - screenRect.origin.y) <= 2 &&
                windowRect.width >= screenRect.width - 2 &&
                windowRect.height >= screenRect.height - 2
            }
        }
    }
}
