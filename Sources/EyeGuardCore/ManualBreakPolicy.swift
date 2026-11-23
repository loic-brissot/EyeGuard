import Foundation

/// Controls how completing a manual break affects the background recurring work interval timer.
public enum ManualBreakCompletionBehavior: String, Equatable, Codable, Sendable, CaseIterable {
    /// Completing a manual break starts a fresh background work cycle.
    /// Skipping a manual break restores the remaining work time captured before the break.
    case resetIntervalTimer

    /// Completing or skipping a manual break restores the paused background work timer
    /// with its remaining duration (or starts fresh if none was active).
    case restoreIntervalTimer
}

/// Outcome of an active manual break session.
public enum ManualBreakOutcome: String, Equatable, Codable, Sendable {
    case completed
    case skipped
}

/// A reusable user-configured manual break preset triggered on demand.
public struct ManualBreakPreset: Identifiable, Equatable, Codable, Sendable {
    public static let minimumDurationSeconds = 10
    public static let maximumDurationSeconds = 180 * 60
    public static let quickDurationMinutes: [Int] = [2, 5, 10, 15]
    public static let quickDurationSeconds: [Int] = quickDurationMinutes.map { $0 * 60 }

    public let id: UUID
    public var name: String
    public var durationSeconds: Int
    public var completionBehavior: ManualBreakCompletionBehavior?

    public init(
        id: UUID = UUID(),
        name: String,
        durationSeconds: Int,
        completionBehavior: ManualBreakCompletionBehavior? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.durationSeconds = Self.clampedDurationSeconds(durationSeconds)
        self.completionBehavior = completionBehavior
    }

    public init(
        id: UUID = UUID(),
        name: String,
        durationMinutes: Int,
        completionBehavior: ManualBreakCompletionBehavior? = nil
    ) {
        self.init(
            id: id,
            name: name,
            durationSeconds: max(1, durationMinutes) * 60,
            completionBehavior: completionBehavior
        )
    }

    public static func clampedDurationSeconds(_ rawSeconds: Int) -> Int {
        min(maximumDurationSeconds, max(minimumDurationSeconds, rawSeconds))
    }

    public var durationMinutes: Int {
        max(1, Int(round(Double(durationSeconds) / 60.0)))
    }

    public var formattedDuration: String {
        let mins = durationSeconds / 60
        let secs = durationSeconds % 60
        if mins == 0 {
            return "\(secs)s"
        }
        if secs == 0 {
            return "\(mins)m"
        }
        return "\(mins)m \(secs)s"
    }
}

/// Persisted configuration for on-demand manual breaks and manual-only mode.
public struct ManualBreakSettings: Equatable, Codable, Sendable {
    public var isManualOnlyMode: Bool
    public var presets: [ManualBreakPreset]
    public var completionBehavior: ManualBreakCompletionBehavior

    public init(
        isManualOnlyMode: Bool = false,
        presets: [ManualBreakPreset] = [],
        completionBehavior: ManualBreakCompletionBehavior = .resetIntervalTimer
    ) {
        self.isManualOnlyMode = isManualOnlyMode
        self.presets = presets
        self.completionBehavior = completionBehavior
    }

    public func adding(_ preset: ManualBreakPreset) -> ManualBreakSettings {
        var copy = self
        copy.add(preset)
        return copy
    }

    public mutating func add(_ preset: ManualBreakPreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
    }

    public func updating(_ preset: ManualBreakPreset) -> ManualBreakSettings {
        var copy = self
        copy.update(preset)
        return copy
    }

    public mutating func update(_ preset: ManualBreakPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }

    public func removing(id: UUID) -> ManualBreakSettings {
        var copy = self
        copy.remove(id: id)
        return copy
    }

    public mutating func remove(id: UUID) {
        presets.removeAll { $0.id == id }
    }
}

/// Runtime snapshot of an in-progress on-demand manual break.
public struct ActiveManualBreak: Equatable, Sendable {
    public let title: String
    public let durationSeconds: Int
    public let startedAt: Date
    public let presetID: UUID?
    public let savedBackgroundWorkRemaining: TimeInterval?
    public let wasInManualOnlyMode: Bool
    public let completionBehaviorOverride: ManualBreakCompletionBehavior?

    public init(
        title: String,
        durationSeconds: Int,
        startedAt: Date,
        presetID: UUID? = nil,
        savedBackgroundWorkRemaining: TimeInterval? = nil,
        wasInManualOnlyMode: Bool = false,
        completionBehaviorOverride: ManualBreakCompletionBehavior? = nil
    ) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.durationSeconds = ManualBreakPreset.clampedDurationSeconds(durationSeconds)
        self.startedAt = startedAt
        self.presetID = presetID
        self.savedBackgroundWorkRemaining = savedBackgroundWorkRemaining.map { max(0, $0) }
        self.wasInManualOnlyMode = wasInManualOnlyMode
        self.completionBehaviorOverride = completionBehaviorOverride
    }
}

/// Deterministic action to apply to the background interval timer when a manual break finishes.
public enum ManualBreakPostAction: Equatable, Sendable {
    /// Manual-only mode is active; stay idle with no recurring interval timer.
    case idleManualOnly
    /// Start a fresh recurring work cycle with the specified full duration.
    case resetWorkCycle(duration: TimeInterval)
    /// Restore the background interval timer with its captured remaining work duration.
    case restoreWorkCycle(remainingSeconds: TimeInterval)
}

/// Pure, deterministic policy managing on-demand manual breaks, presets, and timer restoration.
public struct ManualBreakPolicy: Sendable {
    public init() {}

    public func validatedDurationSeconds(_ rawSeconds: Int) -> Int {
        ManualBreakPreset.clampedDurationSeconds(rawSeconds)
    }

    public func validatedDurationSeconds(minutes: Int, seconds: Int = 0) -> Int {
        let total = max(0, minutes) * 60 + max(0, seconds)
        return ManualBreakPreset.clampedDurationSeconds(total)
    }

    public func startManualBreak(
        title: String,
        durationSeconds: Int,
        presetID: UUID? = nil,
        now: Date,
        currentWorkRemaining: TimeInterval?,
        isManualOnlyMode: Bool,
        isNightLocked: Bool = false,
        completionBehaviorOverride: ManualBreakCompletionBehavior? = nil
    ) -> ActiveManualBreak? {
        guard !isNightLocked else {
            return nil
        }

        let capturedRemaining: TimeInterval?
        if isManualOnlyMode {
            capturedRemaining = nil
        } else if let currentWorkRemaining, currentWorkRemaining > 0 {
            capturedRemaining = currentWorkRemaining
        } else {
            capturedRemaining = nil
        }

        return ActiveManualBreak(
            title: title,
            durationSeconds: validatedDurationSeconds(durationSeconds),
            startedAt: now,
            presetID: presetID,
            savedBackgroundWorkRemaining: capturedRemaining,
            wasInManualOnlyMode: isManualOnlyMode,
            completionBehaviorOverride: completionBehaviorOverride
        )
    }

    public func finishManualBreak(
        _ active: ActiveManualBreak,
        outcome: ManualBreakOutcome,
        settings: ManualBreakSettings,
        fullWorkDuration: TimeInterval,
        now: Date
    ) -> ManualBreakPostAction {
        if settings.isManualOnlyMode {
            return .idleManualOnly
        }

        let effectiveFullWork = max(1, fullWorkDuration)
        let effectiveBehavior = active.completionBehaviorOverride ?? settings.completionBehavior

        switch outcome {
        case .skipped:
            if let saved = active.savedBackgroundWorkRemaining, saved > 0 {
                return .restoreWorkCycle(remainingSeconds: min(effectiveFullWork, saved))
            }
            return .resetWorkCycle(duration: effectiveFullWork)

        case .completed:
            switch effectiveBehavior {
            case .resetIntervalTimer:
                return .resetWorkCycle(duration: effectiveFullWork)
            case .restoreIntervalTimer:
                if let saved = active.savedBackgroundWorkRemaining, saved > 0 {
                    return .restoreWorkCycle(remainingSeconds: min(effectiveFullWork, saved))
                }
                return .resetWorkCycle(duration: effectiveFullWork)
            }
        }
    }

    public func finishManualBreak(
        _ active: ActiveManualBreak,
        outcome: ManualBreakOutcome,
        fullWorkDuration: TimeInterval,
        now: Date
    ) -> ManualBreakPostAction {
        let defaultSettings = ManualBreakSettings(isManualOnlyMode: active.wasInManualOnlyMode)
        return finishManualBreak(
            active,
            outcome: outcome,
            settings: defaultSettings,
            fullWorkDuration: fullWorkDuration,
            now: now
        )
    }
}
