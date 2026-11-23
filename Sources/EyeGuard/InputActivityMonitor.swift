import Cocoa
import CoreGraphics
import EyeGuardCore

protocol InputActivityProviding {
    func currentActivity(now: Date) -> InputActivityState
    func resetTracking()
}

/// Reads keyboard and mouse-drag activity from macOS without requiring Accessibility permission.
final class SystemInputActivityMonitor: InputActivityProviding {
    private var wasMouseButtonDown = false
    private var lastMouseReleaseDate: Date?

    func currentActivity(now: Date = Date()) -> InputActivityState {
        let keyAge = finiteNonNegativeInterval(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        )

        let isMouseDown = NSEvent.pressedMouseButtons != 0
        if isMouseDown {
            wasMouseButtonDown = true
            lastMouseReleaseDate = nil
        } else if wasMouseButtonDown {
            wasMouseButtonDown = false
            lastMouseReleaseDate = now
        }

        let dragEventAge = [
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDragged),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDragged),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .otherMouseDragged)
        ]
        .compactMap(finiteNonNegativeInterval)
        .min()

        let releaseAge: TimeInterval?
        if isMouseDown {
            releaseAge = nil
        } else if let releaseDate = lastMouseReleaseDate {
            let trackedAge = max(0, now.timeIntervalSince(releaseDate))
            if let dragEventAge {
                releaseAge = min(trackedAge, dragEventAge)
            } else {
                releaseAge = trackedAge
            }
        } else {
            releaseAge = dragEventAge
        }

        return InputActivityState(
            secondsSinceLastKeystroke: keyAge,
            isMouseButtonDown: isMouseDown,
            secondsSinceLastDragRelease: releaseAge
        )
    }

    func resetTracking() {
        wasMouseButtonDown = false
        lastMouseReleaseDate = nil
    }

    private func finiteNonNegativeInterval(_ value: CFTimeInterval) -> TimeInterval? {
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }
}
