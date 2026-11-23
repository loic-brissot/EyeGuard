import CoreGraphics
import Foundation

/// Monitors system-wide user inactivity via CoreGraphics without requiring Accessibility permission.
final class IdleMonitor {
    var onUpdate: ((TimeInterval) -> Void)?

    private let pollInterval: TimeInterval
    private var pollTimer: Timer?
    private(set) var lastIdleSeconds: TimeInterval = 0

    init(pollInterval: TimeInterval = 1.5) {
        self.pollInterval = pollInterval
    }

    deinit {
        stop()
    }

    func start() {
        stop()
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
    }

    @discardableResult
    func pollNow() -> TimeInterval {
        let idleSeconds = currentIdleSeconds()
        lastIdleSeconds = idleSeconds
        onUpdate?(idleSeconds)
        return idleSeconds
    }

    func currentIdleSeconds() -> TimeInterval {
        let anyInputEvent = CGEventType(rawValue: ~0) ?? .null
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
        guard seconds.isFinite, seconds >= 0 else {
            return 0
        }
        return seconds
    }
}
