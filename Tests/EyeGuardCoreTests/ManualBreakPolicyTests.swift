import XCTest
@testable import EyeGuardCore

final class ManualBreakPolicyTests: XCTestCase {
    private let policy = ManualBreakPolicy()

    func testPresetCRUDAndCodableRoundTrip() throws {
        var settings = ManualBreakSettings()
        XCTAssertFalse(settings.isManualOnlyMode)
        XCTAssertTrue(settings.presets.isEmpty)

        let stretch = ManualBreakPreset(name: "Deep Stretch", durationMinutes: 5)
        let coffee = ManualBreakPreset(name: "Coffee Walk", durationSeconds: 10 * 60)

        settings = settings.adding(stretch).adding(coffee)
        XCTAssertEqual(settings.presets.count, 2)
        XCTAssertEqual(stretch.durationSeconds, 300)
        XCTAssertEqual(stretch.formattedDuration, "5m")

        var updatedStretch = stretch
        updatedStretch.name = "Desk Stretch"
        updatedStretch.durationSeconds = 90
        settings = settings.updating(updatedStretch)
        XCTAssertEqual(settings.presets.first?.name, "Desk Stretch")
        XCTAssertEqual(settings.presets.first?.formattedDuration, "1m 30s")

        settings.isManualOnlyMode = true
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ManualBreakSettings.self, from: encoded)
        XCTAssertEqual(decoded, settings)

        settings = settings.removing(id: stretch.id)
        XCTAssertEqual(settings.presets, [coffee])
    }

    func testQuickDurationsAndCustomDurationValidation() {
        XCTAssertEqual(ManualBreakPreset.quickDurationMinutes, [2, 5, 10, 15])
        XCTAssertEqual(ManualBreakPreset.quickDurationSeconds, [120, 300, 600, 900])

        XCTAssertEqual(policy.validatedDurationSeconds(3), ManualBreakPreset.minimumDurationSeconds)
        XCTAssertEqual(policy.validatedDurationSeconds(999 * 60), ManualBreakPreset.maximumDurationSeconds)
        XCTAssertEqual(policy.validatedDurationSeconds(minutes: 7, seconds: 30), 450)
        XCTAssertEqual(policy.validatedDurationSeconds(minutes: 0, seconds: 0), ManualBreakPreset.minimumDurationSeconds)
    }

    func testStartingManualBreakCapturesRemainingWorkAndRespectsNightLock() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let blocked = policy.startManualBreak(
            title: "Quick Break",
            durationSeconds: 300,
            now: now,
            currentWorkRemaining: 840,
            isManualOnlyMode: false,
            isNightLocked: true
        )
        XCTAssertNil(blocked)

        let started = policy.startManualBreak(
            title: "  Quick Break  ",
            durationSeconds: 300,
            now: now,
            currentWorkRemaining: 840,
            isManualOnlyMode: false,
            isNightLocked: false
        )
        XCTAssertEqual(started?.title, "Quick Break")
        XCTAssertEqual(started?.durationSeconds, 300)
        XCTAssertEqual(started?.savedBackgroundWorkRemaining, 840)
        XCTAssertFalse(started?.wasInManualOnlyMode ?? true)
    }

    func testCompletingManualBreakResetsBackgroundIntervalTimer() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = ManualBreakSettings(isManualOnlyMode: false, completionBehavior: .resetIntervalTimer)

        let active = policy.startManualBreak(
            title: "5m Break",
            durationSeconds: 300,
            now: now,
            currentWorkRemaining: 750,
            isManualOnlyMode: false
        )!

        let action = policy.finishManualBreak(
            active,
            outcome: .completed,
            settings: settings,
            fullWorkDuration: 1200,
            now: now.addingTimeInterval(300)
        )
        XCTAssertEqual(action, .resetWorkCycle(duration: 1200))
    }

    func testSkippingManualBreakRestoresCapturedRemainingWorkTime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let settings = ManualBreakSettings(isManualOnlyMode: false, completionBehavior: .resetIntervalTimer)

        let active = policy.startManualBreak(
            title: "5m Break",
            durationSeconds: 300,
            now: now,
            currentWorkRemaining: 750,
            isManualOnlyMode: false
        )!

        let skipAction = policy.finishManualBreak(
            active,
            outcome: .skipped,
            settings: settings,
            fullWorkDuration: 1200,
            now: now.addingTimeInterval(45)
        )
        XCTAssertEqual(skipAction, .restoreWorkCycle(remainingSeconds: 750))

        let activeWithoutSaved = policy.startManualBreak(
            title: "5m Break",
            durationSeconds: 300,
            now: now,
            currentWorkRemaining: nil,
            isManualOnlyMode: false
        )!
        let fallbackAction = policy.finishManualBreak(
            activeWithoutSaved,
            outcome: .skipped,
            settings: settings,
            fullWorkDuration: 1200,
            now: now.addingTimeInterval(45)
        )
        XCTAssertEqual(fallbackAction, .resetWorkCycle(duration: 1200))
    }

    func testManualOnlyModeStaysIdleOnCompleteAndSkip() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let manualOnlySettings = ManualBreakSettings(isManualOnlyMode: true)

        let active = policy.startManualBreak(
            title: "Coffee Walk",
            durationSeconds: 600,
            now: now,
            currentWorkRemaining: 500,
            isManualOnlyMode: true
        )!
        XCTAssertNil(active.savedBackgroundWorkRemaining)
        XCTAssertTrue(active.wasInManualOnlyMode)

        let completeAction = policy.finishManualBreak(
            active,
            outcome: .completed,
            settings: manualOnlySettings,
            fullWorkDuration: 1200,
            now: now.addingTimeInterval(600)
        )
        XCTAssertEqual(completeAction, .idleManualOnly)

        let skipAction = policy.finishManualBreak(
            active,
            outcome: .skipped,
            settings: manualOnlySettings,
            fullWorkDuration: 1200,
            now: now.addingTimeInterval(30)
        )
        XCTAssertEqual(skipAction, .idleManualOnly)
    }

    func testSwitchingOutOfManualOnlyModeResumesRecurringCycleOnFinish() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let active = policy.startManualBreak(
            title: "Coffee Walk",
            durationSeconds: 600,
            now: now,
            currentWorkRemaining: nil,
            isManualOnlyMode: true
        )!

        let recurringSettings = ManualBreakSettings(isManualOnlyMode: false)
        let action = policy.finishManualBreak(
            active,
            outcome: .completed,
            settings: recurringSettings,
            fullWorkDuration: 1200,
            now: now.addingTimeInterval(600)
        )
        XCTAssertEqual(action, .resetWorkCycle(duration: 1200))
    }
}
