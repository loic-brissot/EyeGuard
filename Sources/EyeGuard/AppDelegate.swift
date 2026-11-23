import Cocoa
import ServiceManagement
import EyeGuardCore

class AppDelegate: NSObject, NSApplicationDelegate {
    private let checkSingleInstanceOnLaunch: Bool

    init(checkSingleInstanceOnLaunch: Bool = true) {
        self.checkSingleInstanceOnLaunch = checkSingleInstanceOnLaunch
        super.init()
    }
    private enum AppIdentity {
        static let displayName = "EyeGuard"
        static let bundleIdentifier = "com.eyeguard.app"
    }

    private enum NightOverrideDefaults {
        static let grantedAt = "nightOverrideGrantedAt"
        static let until = "nightOverrideUntil"
        static let reason = "nightOverrideReason"
        static let nightKey = "nightOverrideNightKey"
        static let numberForNight = "nightOverrideNumberForNight"
        static let countNightKey = "nightOverrideCountNightKey"
        static let countForNight = "nightOverrideCountForNight"
        static let legacyOverrideUntil = "nightLockOverrideUntil"
        static let legacyTestingExit = "nightTestingExitEnabled"
    }

    private enum TemporaryDisableDefaults {
        static let startedAt = "temporaryDisableStartedAt"
        static let until = "temporaryDisableUntil"
    }

    private enum PlannedBreakDefaults {
        static let settings = "plannedBreakSettings"
    }

    private enum CalendarBreakDefaults {
        static let settings = "calendarBreakSettings"
    }

    private enum ManualBreakDefaults {
        static let settings = "manualBreakSettings"
    }

    private enum SmartPauseDefaults {
        static let screenCaptureEnabled = "smartPauseScreenCaptureEnabled"
        static let meetingAutoPauseEnabled = "smartPauseMeetingAutoPauseEnabled"
        static let meetingExcludedApps = "smartPauseMeetingExcludedApps"
        static let calendarEnabled = "smartPauseCalendarEnabled"
        static let calendarSelectedIDs = "smartPauseCalendarSelectedIDs"
        static let calendarBreakAction = "smartPauseCalendarBreakAction"
        static let fullscreenPauseEnabled = "smartPauseFullscreenEnabled"
        static let deepFocusApps = "smartPauseDeepFocusApps"
        static let waitForInputEnabled = "smartPauseWaitForInputEnabled"
        static let waitForInputMaxSeconds = "smartPauseWaitForInputMaxSeconds"
        static let idlePauseEnabled = "smartPauseIdleEnabled"
        static let idleThresholdSeconds = "smartPauseIdleThresholdSeconds"
    }

    private struct SmartPauseSnapshot {
        var remainingWorkTime: TimeInterval?
        var remainingPostponeTime: TimeInterval?
        var hadDeferredBreak: Bool
        var shouldResetToFreshWorkOnResume: Bool = false
    }

    private var statusBarItem: NSStatusItem!
    private var menu: NSMenu!
    private var stateSnapshotTimer: Timer?
    private var schedulingReady = false
    private var displaysAreActive = true
    private var menuIsOpen = false
    private let timingProbeEnabled = ProcessInfo.processInfo.environment["EYEGUARD_TIMING_PROBE"] == "1"
    private lazy var countdownScheduler: CountdownScheduler = {
        let scheduler = CountdownScheduler()
        scheduler.onDeadline = { [weak self] in self?.handleCountdownDeadline() }
        scheduler.onDisplay = { [weak self] in self?.refreshCountdownDisplayAndTimer() }
        return scheduler
    }()
    private lazy var statusBarIcon: NSImage? = {
        let icon = loadStatusBarIcon() ?? NSImage(systemSymbolName: "eye", accessibilityDescription: "EyeGuard")
        icon?.isTemplate = true
        return icon
    }()
    
    // 绝对时间记录
    private var workSessionStartTime: Date?
    private var breakSessionStartTime: Date?
    
    // 推迟状态跟踪
    private var postponeStartTime: Date?
    private var postponeDuration: TimeInterval = 0
    private var totalPostponedTime: TimeInterval = 0  // 累计推迟时间（秒）
    private var maxTotalPostponeTime: TimeInterval = 5 * 60  // 默认最多推迟5分钟
    
    private var timerMenuItem: NSMenuItem!
    private var breakOverlays: [BreakOverlayWindow] = []
    private var nightLockOverlays: [NightRestrictionOverlayWindow] = []
    private var loginItemMenuItem: NSMenuItem!
    private var temporaryDisableMenuItem: NSMenuItem!
    private var nightRestrictionMenuItem: NSMenuItem!
    private var healthStatsWindow: StatsDashboardWindow?
    
    // 事件记录器（新的统一系统）
    private let eventRecorder = EventRecorder.shared
    // 保留日志管理器用于会话恢复
    private let logManager = LogManager.shared
    
    // Mode settings
    private var currentWorkDuration: Int = 20 * 60 // Default 20 minutes
    private var currentBreakDuration: Int = 20 // Default 20 seconds
    private var isCustomMode: Bool = false
    private var customWorkDuration: Int = 30 * 60 // Default custom: 30 minutes
    private var customBreakDuration: Int = 30 // Default custom: 30 seconds
    private var customPostponeLimitMinutes: Int = 5 // Default custom postpone limit
    private var modeMenuItems: [NSMenuItem] = []
    private var workDurationMenuItems: [NSMenuItem] = []
    private var breakDurationMenuItems: [NSMenuItem] = []
    private var postponeLimitMenuItems: [NSMenuItem] = []
    private var showCountdownInStatusBar: Bool = false
    private var showCountdownMenuItem: NSMenuItem!
    private let preBreakPolicy = PreBreakHeadsUpPolicy()
    private var preBreakLeadTime: PreBreakLeadTime = .defaultLeadTime
    private var preBreakHUDWindow: PreBreakHUDWindow?
    private var preBreakLeadTimeMenuItems: [NSMenuItem] = []

    // Break skip settings
    private var breakSkipSettings = BreakSkipSettings()
    private let breakSkipPolicy = BreakSkipPolicy()
    private var strictModeMenuItem: NSMenuItem!
    private var skipDelayMenuItems: [NSMenuItem] = []

    // Planned breaks settings & runtime state
    private let plannedBreakPolicy = PlannedBreakPolicy()
    private var plannedBreakSettings = PlannedBreakSettings()
    private var plannedBreakState = PlannedBreakRuntimeState()
    private var activePlannedBreakOccurrence: PlannedBreakOccurrence?
    private var activeBreakDurationOverrideSeconds: Int?
    private var plannedBreaksMenuItem: NSMenuItem!
    private var awayStartedAtForPlannedBreak: Date?

    // Calendar-event-driven breaks settings & runtime state
    private let calendarBreakPolicy = CalendarBreakPolicy()
    private var calendarBreakSettings = CalendarBreakSettings()
    private var calendarBreakState = CalendarBreakRuntimeState()
    private var activeCalendarBreakOccurrence: CalendarBreakOccurrence?
    private var calendarBreaksMenuItem: NSMenuItem!

    // On-demand manual breaks settings & runtime state
    private let manualBreakPolicy = ManualBreakPolicy()
    private var manualBreakSettings = ManualBreakSettings()
    private var activeManualBreak: ActiveManualBreak?
    private var manualBreakMenuItem: NSMenuItem!

    // Night restriction settings
    private var nightPolicy = NightRestrictionPolicy()
    private var nightOverridePolicy = NightOverridePolicy()
    private let temporaryDisablePolicy = TemporaryDisablePolicy()
    private var nightRestrictionSettings = NightRestrictionSettings()
    private var nightOverrideState: NightOverrideState?
    private var temporaryDisableState: TemporaryDisableState?

    // Smart Pause settings & runtime state
    private let smartPausePolicy = SmartPausePolicy()
    private var screenCaptureSettings = ScreenCaptureSettings()
    private var meetingAutoPauseSettings = MeetingAutoPauseSettings()
    private var calendarPauseSettings = CalendarPauseSettings()
    private var focusAppPauseSettings = FocusAppPauseSettings()
    private let idleNaturalBreakPolicy = IdleNaturalBreakPolicy()
    private var idleNaturalBreakSettings = IdleNaturalBreakSettings()
    private lazy var screenCaptureMonitor = ScreenCaptureMonitor()
    private lazy var meetingCallMonitor = MeetingCallMonitor()
    private lazy var calendarEventMonitor = CalendarEventMonitor()
    private lazy var focusAppMonitor = FocusAppMonitor()
    private lazy var idleMonitor = IdleMonitor()
    private var idleState: IdleState = .active
    private var smartPauseEvaluation: SmartPauseEvaluation = .activeNone
    private var smartPauseSnapshot: SmartPauseSnapshot?
    private var smartPauseMenuItem: NSMenuItem!
    private let inputDeferralPolicy = InputActivityDeferralPolicy()
    private var inputDeferralSettings = InputDeferralSettings()
    private var inputActivityProvider: InputActivityProviding = SystemInputActivityMonitor()
    private var inputDeferralStartedAt: Date?
    private var inputDeferralReason: InputDeferralReason?
    private var inputDeferralTimer: Timer?
    
    // Language settings
    private var currentLanguage: String = ""
    private var languageMenuItems: [NSMenuItem] = []
    
    // Protection flags
    private var isCompletingWorkSession = false
    private var isCompletingBreakSession = false
    private var isPausedBySystemEvent = false
    
    // MARK: - Computed Properties for Time Calculation

    private var effectiveWorkDuration: Int {
        currentNightStatus().effectiveWorkDurationSeconds
    }
    
    private var workTimeRemaining: TimeInterval {
        guard let startTime = workSessionStartTime else {
            return TimeInterval(effectiveWorkDuration)
        }
        let elapsed = Date().timeIntervalSince(startTime)
        return max(0, TimeInterval(effectiveWorkDuration) - elapsed)
    }
    
    private var effectiveBreakDuration: Int {
        activeBreakDurationOverrideSeconds ?? currentBreakDuration
    }

    private var breakTimeRemaining: TimeInterval {
        guard let startTime = breakSessionStartTime else {
            return TimeInterval(effectiveBreakDuration)
        }
        let elapsed = Date().timeIntervalSince(startTime)
        return max(0, TimeInterval(effectiveBreakDuration) - elapsed)
    }
    
    private var isWorkSessionActive: Bool {
        return workSessionStartTime != nil && workTimeRemaining > 0
    }
    
    private var isBreakSessionActive: Bool {
        return breakSessionStartTime != nil && breakTimeRemaining > 0
    }
    
    private var postponeTimeRemaining: TimeInterval {
        guard let startTime = postponeStartTime else { return 0 }
        let elapsed = Date().timeIntervalSince(startTime)
        return max(0, postponeDuration - elapsed)
    }
    
    private var isPostponeActive: Bool {
        return postponeStartTime != nil && postponeTimeRemaining > 0
    }

    private var temporaryDisableRemainingSeconds: Int {
        temporaryDisablePolicy.remainingSeconds(temporaryDisableState, now: Date())
    }

    private var isTemporaryDisableActive: Bool {
        temporaryDisablePolicy.isActive(temporaryDisableState, now: Date())
    }

    private var isSmartPaused: Bool {
        smartPauseEvaluation.isPaused && !currentNightStatus().isLocked && !isTemporaryDisableActive
    }

    private var isSkippingCalendarBreakActive: Bool {
        guard case .calendarEvent = smartPauseEvaluation.reason else {
            return false
        }
        return calendarPauseSettings.breakAction == .skip
    }

    private var isWaitingForInputDeferral: Bool {
        inputDeferralStartedAt != nil && !currentNightStatus().isLocked && !isTemporaryDisableActive && !isSmartPaused
    }
    
    // MARK: - Localization
    
    // Localization helper
    private func localized(_ key: String) -> String {
        AppLocalization.localized(key, language: currentLanguage)
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 检查是否已有实例运行
        if checkSingleInstanceOnLaunch && !checkSingleInstance() {
            NSApp.terminate(nil)
            return
        }

        loadSettings()
        setupStatusBar()
        setupMenu()
        setupSystemNotifications()
        screenCaptureMonitor.onUpdate = { [weak self] _ in
            self?.evaluateSmartPause()
        }
        meetingCallMonitor.onUpdate = { [weak self] _ in
            self?.evaluateSmartPause()
        }
        calendarEventMonitor.onUpdate = { [weak self] _ in
            self?.evaluateSmartPause()
            self?.rescheduleCountdown()
        }
        focusAppMonitor.onUpdate = { [weak self] _ in
            self?.evaluateSmartPause()
        }
        idleMonitor.onUpdate = { [weak self] _ in
            self?.evaluateSmartPause()
        }
        screenCaptureMonitor.start()
        meetingCallMonitor.start()
        syncCalendarEventMonitorState()
        focusAppMonitor.start()
        idleMonitor.start()
        schedulingReady = true
        
        // 记录应用启动
        eventRecorder.recordAppLaunch()

        // 尝试恢复会话状态，如果无法恢复则启动新的工作会话
        print("🔥 准备恢复会话状态...")
        if !restoreSessionIfNeeded() {
            // 没有有效的会话状态，启动新的工作计时器
            print("🔥 恢复失败，启动新的工作计时器")
            startWorkTimer()
        } else {
            // 成功恢复会话状态，仅启动UI更新计时器
            print("🔥 恢复成功，启动UI更新计时器")
            startUIUpdateTimer()
        }
        
        // 启动状态快照计时器（每10秒记录一次状态）
        startStateSnapshotTimer()
        _ = applyNightRestrictionState(reason: "app_launch")
        rescheduleCountdown()
    }
    
    private func checkSingleInstance() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentExecutablePath = Bundle.main.executablePath
        let conflictingBundleIdentifiers = Set([Bundle.main.bundleIdentifier].compactMap { $0 })
        
        print("检查单实例：当前进程 \(currentPID)，可执行路径：\(currentExecutablePath ?? "unknown")")
        
        // 查找相同可执行路径的其他进程
        let sameApps = runningApps.filter { app in
            guard app.processIdentifier != currentPID else { return false }
            
            // 比较可执行路径
            if let executableURL = app.executableURL,
               let currentPath = currentExecutablePath {
                return executableURL.path == currentPath
            }
            
            // 备选方案：比较 bundle identifier (适用于发布版本)
            if let bundleID = app.bundleIdentifier {
                return conflictingBundleIdentifiers.contains(bundleID)
            }
            
            return false
        }
        
        print("找到相同进程：\(sameApps.count)个")
        
        if !sameApps.isEmpty {
            // 有其他实例运行，记录日志并直接退出（不显示弹窗以避免阻塞）
            print("发现已有实例运行，当前实例将退出")
            logManager.logEvent(.appTerminated, context: ["reason": "duplicate_instance"])
            
            // 激活现有实例
            if let existingApp = sameApps.first {
                existingApp.activate(options: [])
            }
            
            return false
        }
        
        return true
    }

    private func restoreSessionIfNeeded() -> Bool {
        logManager.logEvent(.appLaunched, context: ["debug": "restore_start"])
        logSessionDebug("restore_session_started")

        if restoreTemporaryDisableIfNeeded() {
            logSessionDebug("restore_temporary_disable_active")
            return true
        }

        if let savedState = eventRecorder.restoreSessionState() {
            logManager.logEvent(.appLaunched, context: ["debug": "decode_success", "workStartTime": savedState.workStartTime?.description ?? "nil"])
            logSessionDebug("restore_session_decoded", context: [
                "work_start_time": debugTimestamp(savedState.workStartTime),
                "break_start_time": debugTimestamp(savedState.breakStartTime),
                "postpone_start_time": debugTimestamp(savedState.postponeStartTime),
                "postpone_duration": "\(Int(savedState.postponeDuration))",
                "paused_by_system_event": "\(savedState.pausedBySystemEvent)"
            ])
            
            // 重要：不恢复用户配置（isCustomMode, currentWorkDuration, currentBreakDuration）
            // 这些应该始终来自UserDefaults，通过loadSettings()获取
            // 只恢复时间相关的会话状态（开始时间等）
            
            let timeSinceLastSave = Date().timeIntervalSince(savedState.lastSaved)
            logManager.logEvent(.appLaunched, context: ["debug": "time_check", "seconds_since_save": "\(Int(timeSinceLastSave))", "paused_by_system": "\(savedState.pausedBySystemEvent)"])
            
            if savedState.pausedBySystemEvent {
                logManager.logEvent(.appLaunched, context: ["debug": "session_rejected", "reason": "paused_by_system_event"])
                logSessionDebug("restore_session_rejected", context: [
                    "reason": "paused_by_system_event",
                    "work_start_time": debugTimestamp(savedState.workStartTime),
                    "break_start_time": debugTimestamp(savedState.breakStartTime)
                ])
                logManager.logTimerReset(reason: "paused_by_system_event")
                return false
            }

            switch SessionRecoveryPolicy().decision(for: savedState, now: Date()) {
            case .continuePostpone(let startTime, let duration, let savedTotalPostponedTime):
                logManager.logEvent(.appLaunched, context: ["debug": "session_valid", "restore": "active_postpone"])
                logSessionDebug("restore_active_postpone", context: [
                    "postpone_start_time": debugTimestamp(startTime),
                    "postpone_duration": "\(Int(duration))",
                    "total_postponed_time": "\(Int(savedTotalPostponedTime))"
                ])
                workSessionStartTime = nil
                breakSessionStartTime = nil
                postponeStartTime = startTime
                postponeDuration = duration
                totalPostponedTime = savedTotalPostponedTime
                print("🔄 恢复推迟休息，剩余 \(Int(postponeTimeRemaining)) 秒")
                startPostponeTimer()
                return true

            case .startBreakAfterExpiredPostpone(let savedTotalPostponedTime):
                logManager.logEvent(.appLaunched, context: ["debug": "session_valid", "restore": "expired_postpone"])
                logSessionDebug("restore_expired_postpone_to_break", context: [
                    "total_postponed_time": "\(Int(savedTotalPostponedTime))"
                ])
                workSessionStartTime = nil
                breakSessionStartTime = nil
                postponeStartTime = nil
                postponeDuration = 0
                totalPostponedTime = savedTotalPostponedTime
                print("🔄 推迟已过期，立即进入休息")
                showBreakOverlay()
                return true

            case .noPostpone:
                break
            }

            // 使用新的恢复逻辑
            if !savedState.shouldRestoreAfterSystemEvent() {
                let reason = savedState.pausedBySystemEvent ? "paused_by_system_event" : "session_too_old"
                logManager.logEvent(.appLaunched, context: ["debug": "session_rejected", "reason": reason])
                logSessionDebug("restore_session_rejected", context: [
                    "reason": reason,
                    "seconds_since_last_save": "\(Int(timeSinceLastSave))"
                ])
                logManager.logTimerReset(reason: reason)
                return false
            } else {
                logManager.logEvent(.appLaunched, context: ["debug": "session_valid"])
                logSessionDebug("restore_session_valid", context: [
                    "seconds_since_last_save": "\(Int(timeSinceLastSave))"
                ])
            }
            
            // 恢复工作会话
            if let workStart = savedState.workStartTime {
                let workElapsed = Date().timeIntervalSince(workStart)
                let plannedWorkDuration = effectiveWorkDuration
                let maxWorkTime = TimeInterval(plannedWorkDuration) + 2 * 60 // 允许2分钟缓冲
                
                if workElapsed < maxWorkTime {
                    // 继续工作会话
                    workSessionStartTime = workStart
                    // 在数据库中记录恢复的会话，使用原始开始时间
                    logSessionDebug("restore_active_work_session", context: [
                        "work_start_time": debugTimestamp(workStart),
                        "work_elapsed": "\(Int(workElapsed))",
                        "planned_work_duration": "\(plannedWorkDuration)"
                    ])
                    eventRecorder.startWorkSession(duration: plannedWorkDuration, startTime: workStart)
                    print("🔄 恢复工作会话，已用时 \(Int(workElapsed))秒，剩余 \(Int(workTimeRemaining))秒")

                    if workElapsed >= TimeInterval(plannedWorkDuration) {
                        // 工作时间已到，立即进入休息
                        logSessionDebug("restored_work_session_due_for_break", context: [
                            "work_elapsed": "\(Int(workElapsed))",
                            "planned_work_duration": "\(plannedWorkDuration)"
                        ])
                        logManager.logWorkCompleted(duration: workElapsed)
                        showBreakOverlay()
                    }
                    return true
                } else {
                    // 工作时间过长，重置
                    logSessionDebug("restore_work_session_overtime", context: [
                        "work_elapsed": "\(Int(workElapsed))",
                        "planned_work_duration": "\(plannedWorkDuration)"
                    ])
                    logManager.logWorkPaused(duration: workElapsed, reason: "session_overtime")
                    logManager.logTimerReset(reason: "work_session_overtime")
                    return false
                }
            }
            
            // 恢复休息会话
            if let breakStart = savedState.breakStartTime {
                let breakElapsed = Date().timeIntervalSince(breakStart)
                let maxBreakTime = TimeInterval(currentBreakDuration) + 1 * 60 // 允许1分钟缓冲
                
                if breakElapsed < maxBreakTime {
                    // 继续休息会话
                    breakSessionStartTime = breakStart
                    logSessionDebug("restore_active_break_session", context: [
                        "break_start_time": debugTimestamp(breakStart),
                        "break_elapsed": "\(Int(breakElapsed))",
                        "planned_break_duration": "\(currentBreakDuration)"
                    ])
                    print("🔄 恢复休息会话，已用时 \(Int(breakElapsed))秒，剩余 \(Int(breakTimeRemaining))秒")
                    showBreakOverlay()
                    return true
                } else {
                    // 休息时间过长，自动完成休息
                    logSessionDebug("restore_break_session_overtime_completed", context: [
                        "break_elapsed": "\(Int(breakElapsed))",
                        "planned_break_duration": "\(currentBreakDuration)"
                    ])
                    logManager.logBreakCompleted(actualDuration: breakElapsed, expectedDuration: currentBreakDuration)
                    eventRecorder.endBreakSession()
                    logManager.logTimerReset(reason: "break_session_overtime")
                    return false
                }
            }
        }
        
        // 没有有效的保存状态，需要开始新会话
        logManager.logEvent(.appLaunched, context: ["debug": "restore_failed", "reason": "no_session_state"])
        logSessionDebug("restore_session_missing_state")
        return false
    }
    
    private func startUIUpdateTimer() {
        rescheduleCountdown()
    }

    private func remainingWorkTime(at now: Date, status: NightRestrictionStatus) -> TimeInterval {
        guard let start = workSessionStartTime else { return TimeInterval(status.effectiveWorkDurationSeconds) }
        return max(0, TimeInterval(status.effectiveWorkDurationSeconds) - now.timeIntervalSince(start))
    }

    private func countdownPlan(now: Date, status: NightRestrictionStatus) -> CountdownPlan {
        let phase: CountdownPhase
        if !nightLockOverlays.isEmpty && !status.isLocked {
            // Creating a window can straddle unlock (or a clock change). Its old lock still
            // needs an action callback even though the policy already reports normal.
            phase = .nightLocked(until: now)
        } else if status.isLocked {
            phase = .nightLocked(until: status.schedule.unlockTime)
        } else if let state = temporaryDisableState {
            phase = .temporarilyDisabled(until: state.until)
        } else if isSmartPaused {
            phase = .paused
        } else if let start = postponeStartTime {
            phase = .postponed(until: start.addingTimeInterval(postponeDuration))
        } else if let start = breakSessionStartTime {
            phase = .rest(until: start.addingTimeInterval(TimeInterval(effectiveBreakDuration)))
        } else if let start = workSessionStartTime {
            phase = .work(until: start.addingTimeInterval(TimeInterval(status.effectiveWorkDurationSeconds)))
        } else {
            phase = .paused
        }
        let preBreakLeadTimeSeconds: Int
        switch phase {
        case .work:
            preBreakLeadTimeSeconds = preBreakPolicy.effectiveLeadTimeSeconds(
                leadTime: preBreakLeadTime,
                workDurationSeconds: status.effectiveWorkDurationSeconds
            )
        case .postponed:
            preBreakLeadTimeSeconds = preBreakPolicy.effectiveLeadTimeSeconds(
                leadTime: preBreakLeadTime,
                workDurationSeconds: Int(postponeDuration)
            )
        case .rest, .temporarilyDisabled, .nightLocked, .paused:
            preBreakLeadTimeSeconds = 0
        }
        let plannedBreakTransition: Date?
        let calendarBreakTransition: Date?
        if status.isLocked || isTemporaryDisableActive || breakSessionStartTime != nil {
            plannedBreakTransition = nil
            calendarBreakTransition = nil
        } else {
            plannedBreakTransition = plannedBreakPolicy.nextBoundary(
                settings: plannedBreakSettings,
                state: plannedBreakState,
                now: now
            )
            calendarBreakTransition = calendarBreakPolicy.nextBoundary(
                settings: calendarBreakSettings,
                snapshot: calendarEventMonitor.lastSnapshot,
                state: calendarBreakState,
                now: now
            )
        }
        return CountdownTiming.plan(
            now: now, phase: phase,
            nightTransition: nightPolicy.nextTransition(after: now, status: status, isEnabled: nightRestrictionSettings.isEnabled),
            overrideUntil: nightOverrideState?.until,
            plannedBreakTransition: plannedBreakTransition,
            calendarBreakTransition: calendarBreakTransition,
            showStatusCountdown: showCountdownInStatusBar,
            menuIsOpen: menuIsOpen, displaysAreActive: displaysAreActive,
            preBreakLeadTimeSeconds: preBreakLeadTimeSeconds
        )
    }

    private func rescheduleCountdown() {
        guard schedulingReady else { return }
        let now = Date()
        let status = currentNightStatus(now: now)
        refreshCountdownDisplay(now: now, status: status)
        countdownScheduler.schedule(countdownPlan(now: now, status: status))
    }

    private func refreshCountdownDisplayAndTimer() {
        guard schedulingReady else { return }
        let now = Date()
        let status = currentNightStatus(now: now)
        refreshCountdownDisplay(now: now, status: status)
        // Display work never replaces a pending action, even if both fire at the same instant.
        countdownScheduler.scheduleDisplay(countdownPlan(now: now, status: status).display)
    }

    private func refreshCountdownDisplay(now: Date, status: NightRestrictionStatus) {
        guard displaysAreActive else { return }
        if let start = breakSessionStartTime {
            let remaining = CountdownTiming.secondsRemaining(until: start.addingTimeInterval(TimeInterval(effectiveBreakDuration)), now: now)
            let skipState = breakSkipPolicy.state(settings: breakSkipSettings, breakStartTime: start, now: now)
            for overlay in breakOverlays {
                overlay.updateCountdown(remaining)
                overlay.updateSkipState(skipState)
            }
        }
        if status.isLocked {
            for overlay in nightLockOverlays {
                overlay.update(unlockTime: status.schedule.unlockTime, now: now, recoveryFormat: localized("nightOverrideRecoveryFormat"))
            }
        }
        if breakSessionStartTime == nil || status.isLocked || status.isOverrideActive {
            updateStatusBarTitle(now: now, status: status)
        }
        updatePreBreakHUD(now: now, status: status)
        updateMenuTimer(now: now, status: status)
        if menuIsOpen { updateTemporaryDisableMenuItem() }
    }

    private func handleCountdownDeadline() {
        traceCountdownTiming(event: "deadline")
        clearExpiredNightOverride()
        if !nightLockOverlays.isEmpty && !currentNightStatus().isLocked {
            updateNightLockTimer()
        } else if temporaryDisableState != nil {
            updateTemporaryDisableTimer()
        } else if !nightLockOverlays.isEmpty {
            updateNightLockTimer()
        } else if !displaysAreActive {
            _ = applyNightRestrictionState(reason: "scheduled_while_paused")
        } else if evaluatePlannedBreaks(now: Date()) {
            // Planned break evaluation handled the deadline
        } else if evaluateCalendarBreaks(now: Date()) {
            // Calendar break evaluation handled the deadline
        } else if postponeStartTime != nil {
            updatePostponeTimer()
        } else if breakSessionStartTime != nil {
            updateBreakTimer()
        } else if workSessionStartTime != nil {
            updateWorkTimer()
        } else {
            _ = applyNightRestrictionState(reason: "scheduled_boundary")
        }
        rescheduleCountdown()
    }

    @objc private func systemClockOrTimeZoneChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.systemClockOrTimeZoneChanged() }
            return
        }
        // Both policies capture a Calendar. Recreating them matters after a time-zone change.
        nightPolicy = NightRestrictionPolicy()
        nightOverridePolicy = NightOverridePolicy()
        guard schedulingReady else { return }
        countdownScheduler.cancel()
        handleCountdownDeadline()
    }

    private func traceCountdownTiming(event: String) {
        guard timingProbeEnabled else { return }
        let now = String(format: "%.6f", Date().timeIntervalSince1970)
        let planned = String(format: "%.6f", countdownScheduler.lastFiredDeadline?.timeIntervalSince1970 ?? 0)
        let line = "[TimingProbe] event=\(event) now=\(now) planned=\(planned) deadline_callbacks=\(countdownScheduler.deadlineFireCount) display_callbacks=\(countdownScheduler.displayFireCount) title=\(statusBarItem.button?.title ?? "") menu_open=\(menuIsOpen)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }

    #if DEBUG
    var countdownScheduleForTesting: CountdownPlan { countdownScheduler.scheduledPlan }
    var hasNightOverlayForTesting: Bool { !nightLockOverlays.isEmpty }

    func setUnshownNightOverlayForTesting(_ overlay: NightRestrictionOverlayWindow) {
        precondition(!overlay.isVisible)
        nightLockOverlays = [overlay]
        rescheduleCountdown()
    }

    func stopCountdownForTesting() {
        schedulingReady = false
        countdownScheduler.cancel()
        stateSnapshotTimer?.invalidate()
        screenCaptureMonitor.stop()
        meetingCallMonitor.stop()
        calendarEventMonitor.stop()
        focusAppMonitor.stop()
        idleMonitor.stop()
        cancelInputDeferral()
        dismissPreBreakHUD()
        for overlay in nightLockOverlays { overlay.hideOverlay() }
        nightLockOverlays.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        if let item = statusBarItem { NSStatusBar.system.removeStatusItem(item) }
    }
    #endif
    
    private func loadSettings() {
        showCountdownInStatusBar = UserDefaults.standard.bool(forKey: "showCountdownInStatusBar")
        isCustomMode = UserDefaults.standard.bool(forKey: "isCustomMode")
        if let savedPreBreakSeconds = UserDefaults.standard.object(forKey: "preBreakHeadsUpSeconds") as? Int {
            preBreakLeadTime = PreBreakLeadTime.validated(savedPreBreakSeconds)
        } else {
            preBreakLeadTime = .defaultLeadTime
        }
        
        // Load language setting
        if let savedLanguage = UserDefaults.standard.string(forKey: "currentLanguage"),
           AppLocalization.supportedLanguageCodes.contains(savedLanguage) {
            currentLanguage = savedLanguage
        } else {
            // Auto-detect system language
            currentLanguage = AppLocalization.languageCode(for: Locale.preferredLanguages)
        }
        
        let savedCustomWorkDuration = UserDefaults.standard.integer(forKey: "customWorkDuration")
        if savedCustomWorkDuration > 0 {
            customWorkDuration = savedCustomWorkDuration
        }
        
        let savedCustomBreakDuration = UserDefaults.standard.integer(forKey: "customBreakDuration")
        if savedCustomBreakDuration > 0 {
            customBreakDuration = savedCustomBreakDuration
        }

        // Load custom-mode postpone limit setting. Default mode is always fixed at 5 minutes.
        let savedPostponeLimit = UserDefaults.standard.integer(forKey: "maxPostponeMinutes")
        customPostponeLimitMinutes = [5, 10].contains(savedPostponeLimit) ? savedPostponeLimit : 5

        let isStrictMode = UserDefaults.standard.bool(forKey: "breakStrictMode")
        let savedSkipDelay = UserDefaults.standard.object(forKey: "breakSkipDelaySeconds") as? Int
        let skipDelaySeconds = savedSkipDelay.map { BreakSkipSettings.supportedDelaySeconds.contains($0) ? $0 : BreakSkipSettings.defaultDelaySeconds }
            ?? BreakSkipSettings.defaultDelaySeconds
        breakSkipSettings = BreakSkipSettings(
            isStrictMode: isStrictMode,
            skipDelaySeconds: skipDelaySeconds
        )

        nightRestrictionSettings = NightRestrictionSettings(
            isEnabled: UserDefaults.standard.bool(forKey: "nightRestrictionEnabled"),
            windDownStart: loadClockTime(forKey: "nightWindDownStartMinutes", defaultValue: ClockTime(hour: 20, minute: 0)),
            lockStart: loadClockTime(forKey: "nightLockStartMinutes", defaultValue: ClockTime(hour: 21, minute: 0)),
            unlockTime: loadClockTime(forKey: "nightUnlockMinutes", defaultValue: ClockTime(hour: 7, minute: 0))
        )
        cleanupLegacyNightOverrideDefaults()
        nightOverrideState = loadNightOverrideState()
        temporaryDisableState = loadTemporaryDisableState()
        clearExpiredNightOverride()

        if UserDefaults.standard.object(forKey: SmartPauseDefaults.screenCaptureEnabled) != nil {
            screenCaptureSettings.isEnabled = UserDefaults.standard.bool(forKey: SmartPauseDefaults.screenCaptureEnabled)
        } else {
            screenCaptureSettings.isEnabled = true
        }

        if UserDefaults.standard.object(forKey: SmartPauseDefaults.meetingAutoPauseEnabled) != nil {
            meetingAutoPauseSettings.isEnabled = UserDefaults.standard.bool(forKey: SmartPauseDefaults.meetingAutoPauseEnabled)
        } else {
            meetingAutoPauseSettings.isEnabled = true
        }
        meetingAutoPauseSettings.excludedApps = UserDefaults.standard.stringArray(forKey: SmartPauseDefaults.meetingExcludedApps) ?? []

        if UserDefaults.standard.object(forKey: SmartPauseDefaults.calendarEnabled) != nil {
            calendarPauseSettings.isEnabled = UserDefaults.standard.bool(forKey: SmartPauseDefaults.calendarEnabled)
        } else {
            calendarPauseSettings.isEnabled = false
        }
        let savedCalendarIDs = UserDefaults.standard.stringArray(forKey: SmartPauseDefaults.calendarSelectedIDs) ?? []
        calendarPauseSettings.selectedCalendarIDs = Set(savedCalendarIDs)
        if let rawBreakAction = UserDefaults.standard.string(forKey: SmartPauseDefaults.calendarBreakAction),
           let breakAction = CalendarBreakAction(rawValue: rawBreakAction) {
            calendarPauseSettings.breakAction = breakAction
        } else {
            calendarPauseSettings.breakAction = .postpone
        }

        if UserDefaults.standard.object(forKey: SmartPauseDefaults.fullscreenPauseEnabled) != nil {
            focusAppPauseSettings.fullscreenPauseEnabled = UserDefaults.standard.bool(forKey: SmartPauseDefaults.fullscreenPauseEnabled)
        } else {
            focusAppPauseSettings.fullscreenPauseEnabled = true
        }
        if let deepFocusData = UserDefaults.standard.data(forKey: SmartPauseDefaults.deepFocusApps),
           let decodedRules = try? JSONDecoder().decode([DeepFocusAppRule].self, from: deepFocusData) {
            focusAppPauseSettings.deepFocusApps = decodedRules
        } else {
            focusAppPauseSettings.deepFocusApps = []
        }

        let waitForInputEnabled: Bool
        if UserDefaults.standard.object(forKey: SmartPauseDefaults.waitForInputEnabled) != nil {
            waitForInputEnabled = UserDefaults.standard.bool(forKey: SmartPauseDefaults.waitForInputEnabled)
        } else {
            waitForInputEnabled = true
        }
        let savedMaxWaitSeconds = UserDefaults.standard.object(forKey: SmartPauseDefaults.waitForInputMaxSeconds) as? Int
        let validatedMaxWait = InputDeferralSettings.validatedMaxWaitSeconds(
            savedMaxWaitSeconds ?? Int(InputDeferralSettings.defaultMaxWaitThreshold)
        )
        inputDeferralSettings = InputDeferralSettings(
            isEnabled: waitForInputEnabled,
            idleGraceWindow: InputDeferralSettings.defaultIdleGraceWindow,
            maxWaitThreshold: TimeInterval(validatedMaxWait)
        )

        let idleEnabled: Bool
        if UserDefaults.standard.object(forKey: SmartPauseDefaults.idlePauseEnabled) != nil {
            idleEnabled = UserDefaults.standard.bool(forKey: SmartPauseDefaults.idlePauseEnabled)
        } else {
            idleEnabled = true
        }
        let savedIdleThreshold = UserDefaults.standard.object(forKey: SmartPauseDefaults.idleThresholdSeconds) as? Int
        let validatedIdleThreshold = IdleNaturalBreakSettings.supportedIdleThresholds.contains(savedIdleThreshold ?? -1)
            ? (savedIdleThreshold ?? Int(IdleNaturalBreakSettings.defaultIdlePauseThreshold))
            : Int(IdleNaturalBreakSettings.defaultIdlePauseThreshold)
        idleNaturalBreakSettings = IdleNaturalBreakSettings(
            isEnabled: idleEnabled,
            idlePauseThreshold: TimeInterval(validatedIdleThreshold)
        )

        if let plannedBreakData = UserDefaults.standard.data(forKey: PlannedBreakDefaults.settings),
           let decodedPlannedBreaks = try? JSONDecoder().decode(PlannedBreakSettings.self, from: plannedBreakData) {
            plannedBreakSettings = decodedPlannedBreaks
        } else {
            plannedBreakSettings = PlannedBreakSettings()
        }

        if let calendarBreakData = UserDefaults.standard.data(forKey: CalendarBreakDefaults.settings),
           let decodedCalendarBreaks = try? JSONDecoder().decode(CalendarBreakSettings.self, from: calendarBreakData) {
            calendarBreakSettings = decodedCalendarBreaks
        } else {
            calendarBreakSettings = CalendarBreakSettings()
        }

        if let manualBreakData = UserDefaults.standard.data(forKey: ManualBreakDefaults.settings),
           let decodedManualBreaks = try? JSONDecoder().decode(ManualBreakSettings.self, from: manualBreakData) {
            manualBreakSettings = decodedManualBreaks
        } else {
            manualBreakSettings = ManualBreakSettings()
        }

        // Apply the loaded settings
        if isCustomMode {
            currentWorkDuration = customWorkDuration
            currentBreakDuration = customBreakDuration
            maxTotalPostponeTime = TimeInterval(customPostponeLimitMinutes * 60)
        } else {
            currentWorkDuration = 20 * 60
            currentBreakDuration = 20
            maxTotalPostponeTime = 5 * 60
        }
    }
    
    private func saveSettings() {
        UserDefaults.standard.set(showCountdownInStatusBar, forKey: "showCountdownInStatusBar")
        UserDefaults.standard.set(isCustomMode, forKey: "isCustomMode")
        UserDefaults.standard.set(preBreakLeadTime.rawValue, forKey: "preBreakHeadsUpSeconds")
        UserDefaults.standard.set(customWorkDuration, forKey: "customWorkDuration")
        UserDefaults.standard.set(customBreakDuration, forKey: "customBreakDuration")
        UserDefaults.standard.set(currentLanguage, forKey: "currentLanguage")
        UserDefaults.standard.set(customPostponeLimitMinutes, forKey: "maxPostponeMinutes")
        UserDefaults.standard.set(breakSkipSettings.isStrictMode, forKey: "breakStrictMode")
        UserDefaults.standard.set(breakSkipSettings.skipDelaySeconds, forKey: "breakSkipDelaySeconds")
        UserDefaults.standard.set(nightRestrictionSettings.isEnabled, forKey: "nightRestrictionEnabled")
        UserDefaults.standard.set(nightRestrictionSettings.windDownStart.minutesAfterMidnight, forKey: "nightWindDownStartMinutes")
        UserDefaults.standard.set(nightRestrictionSettings.lockStart.minutesAfterMidnight, forKey: "nightLockStartMinutes")
        UserDefaults.standard.set(nightRestrictionSettings.unlockTime.minutesAfterMidnight, forKey: "nightUnlockMinutes")
        UserDefaults.standard.set(screenCaptureSettings.isEnabled, forKey: SmartPauseDefaults.screenCaptureEnabled)
        UserDefaults.standard.set(meetingAutoPauseSettings.isEnabled, forKey: SmartPauseDefaults.meetingAutoPauseEnabled)
        UserDefaults.standard.set(meetingAutoPauseSettings.excludedApps, forKey: SmartPauseDefaults.meetingExcludedApps)
        UserDefaults.standard.set(calendarPauseSettings.isEnabled, forKey: SmartPauseDefaults.calendarEnabled)
        UserDefaults.standard.set(Array(calendarPauseSettings.selectedCalendarIDs).sorted(), forKey: SmartPauseDefaults.calendarSelectedIDs)
        UserDefaults.standard.set(calendarPauseSettings.breakAction.rawValue, forKey: SmartPauseDefaults.calendarBreakAction)
        UserDefaults.standard.set(focusAppPauseSettings.fullscreenPauseEnabled, forKey: SmartPauseDefaults.fullscreenPauseEnabled)
        if let encodedDeepFocus = try? JSONEncoder().encode(focusAppPauseSettings.deepFocusApps) {
            UserDefaults.standard.set(encodedDeepFocus, forKey: SmartPauseDefaults.deepFocusApps)
        }
        UserDefaults.standard.set(inputDeferralSettings.isEnabled, forKey: SmartPauseDefaults.waitForInputEnabled)
        UserDefaults.standard.set(Int(inputDeferralSettings.maxWaitThreshold), forKey: SmartPauseDefaults.waitForInputMaxSeconds)
        UserDefaults.standard.set(idleNaturalBreakSettings.isEnabled, forKey: SmartPauseDefaults.idlePauseEnabled)
        UserDefaults.standard.set(Int(idleNaturalBreakSettings.idlePauseThreshold), forKey: SmartPauseDefaults.idleThresholdSeconds)
        if let encodedPlannedBreaks = try? JSONEncoder().encode(plannedBreakSettings) {
            UserDefaults.standard.set(encodedPlannedBreaks, forKey: PlannedBreakDefaults.settings)
        }
        if let encodedCalendarBreaks = try? JSONEncoder().encode(calendarBreakSettings) {
            UserDefaults.standard.set(encodedCalendarBreaks, forKey: CalendarBreakDefaults.settings)
        }
        if let encodedManualBreaks = try? JSONEncoder().encode(manualBreakSettings) {
            UserDefaults.standard.set(encodedManualBreaks, forKey: ManualBreakDefaults.settings)
        }

        // 记录设置变更
        let changes: [String: String] = [
            "show_countdown": "\(showCountdownInStatusBar)",
            "pre_break_heads_up_seconds": "\(preBreakLeadTime.rawValue)",
            "custom_mode": "\(isCustomMode)",
            "custom_work_duration": "\(customWorkDuration)",
            "custom_break_duration": "\(customBreakDuration)",
            "language": currentLanguage,
            "custom_postpone_limit_minutes": "\(customPostponeLimitMinutes)",
            "effective_postpone_limit_minutes": "\(Int(maxTotalPostponeTime / 60))",
            "break_strict_mode": "\(breakSkipSettings.isStrictMode)",
            "break_skip_delay_seconds": "\(breakSkipSettings.skipDelaySeconds)",
            "night_restriction_enabled": "\(nightRestrictionSettings.isEnabled)",
            "night_wind_down_start": nightRestrictionSettings.windDownStart.displayString,
            "night_lock_start": nightRestrictionSettings.lockStart.displayString,
            "night_unlock_time": nightRestrictionSettings.unlockTime.displayString,
            "smart_pause_screen_capture_enabled": "\(screenCaptureSettings.isEnabled)",
            "smart_pause_meeting_enabled": "\(meetingAutoPauseSettings.isEnabled)",
            "smart_pause_excluded_count": "\(meetingAutoPauseSettings.excludedApps.count)",
            "smart_pause_calendar_enabled": "\(calendarPauseSettings.isEnabled)",
            "smart_pause_calendar_selected_count": "\(calendarPauseSettings.selectedCalendarIDs.count)",
            "smart_pause_calendar_break_action": calendarPauseSettings.breakAction.rawValue,
            "smart_pause_fullscreen_enabled": "\(focusAppPauseSettings.fullscreenPauseEnabled)",
            "smart_pause_deep_focus_count": "\(focusAppPauseSettings.deepFocusApps.count)",
            "smart_pause_wait_for_input_enabled": "\(inputDeferralSettings.isEnabled)",
            "smart_pause_wait_for_input_max_seconds": "\(Int(inputDeferralSettings.maxWaitThreshold))",
            "smart_pause_idle_enabled": "\(idleNaturalBreakSettings.isEnabled)",
            "smart_pause_idle_threshold_seconds": "\(Int(idleNaturalBreakSettings.idlePauseThreshold))",
            "planned_breaks_count": "\(plannedBreakSettings.schedules.count)",
            "calendar_breaks_enabled": "\(calendarBreakSettings.isEnabled)",
            "calendar_breaks_has_calendar": "\(calendarBreakSettings.selectedCalendarID != nil)",
            "calendar_breaks_has_filter": "\(!calendarBreakSettings.trimmedTitleFilter.isEmpty)"
        ]
        eventRecorder.recordSettingsChange(changes: changes)
    }
    
    private func setupStatusBar() {
        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusBarItem.button {
            button.image = statusBarIcon
            button.action = #selector(statusBarButtonClicked)
            button.target = self
        }
        
        updateStatusBarTitle()
    }
    
    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self
        
        timerMenuItem = NSMenuItem(title: formatWorkTime(workTimeRemaining), action: nil, keyEquivalent: "")
        timerMenuItem.isEnabled = false
        menu.addItem(timerMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        let testBreakItem = NSMenuItem(title: localized("testBreak"), action: #selector(triggerTestBreak), keyEquivalent: "t")
        testBreakItem.target = self
        testBreakItem.keyEquivalentModifierMask = .command
        menu.addItem(testBreakItem)

        setupManualBreakMenu()

        temporaryDisableMenuItem = NSMenuItem(title: localized("temporaryDisableOneHour"), action: #selector(toggleTemporaryDisable), keyEquivalent: "d")
        temporaryDisableMenuItem.target = self
        temporaryDisableMenuItem.keyEquivalentModifierMask = .command
        updateTemporaryDisableMenuItem()
        menu.addItem(temporaryDisableMenuItem)
        
        let healthStatsItem = NSMenuItem(title: localized("eyeHealthStats"), action: #selector(showHealthStats), keyEquivalent: "s")
        healthStatsItem.target = self
        healthStatsItem.keyEquivalentModifierMask = .command
        menu.addItem(healthStatsItem)

        menu.addItem(NSMenuItem.separator())
        
        setupModeMenu()
        setupPlannedBreaksMenu()
        setupCalendarBreaksMenu()
        setupNightRestrictionMenu()
        setupSmartPauseMenu()
        
        menu.addItem(NSMenuItem.separator())
        
        let settingsLabel = NSMenuItem(title: localized("settings"), action: nil, keyEquivalent: "")
        settingsLabel.isEnabled = false
        menu.addItem(settingsLabel)
        
        // Language selection menu
        let languageItem = NSMenuItem(title: localized("language"), action: nil, keyEquivalent: "")
        let languageSubmenu = NSMenu()
        
        for (langCode, langName) in AppLocalization.languageDisplayNames {
            let item = NSMenuItem(title: langName, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = langCode
            item.state = (currentLanguage == langCode) ? .on : .off
            languageSubmenu.addItem(item)
            languageMenuItems.append(item)
        }
        
        languageItem.submenu = languageSubmenu
        menu.addItem(languageItem)
        
        loginItemMenuItem = NSMenuItem(title: localized("loginAtStartup"), action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItemMenuItem.target = self
        updateLoginItemState()
        menu.addItem(loginItemMenuItem)
        
        showCountdownMenuItem = NSMenuItem(title: localized("showCountdown"), action: #selector(toggleShowCountdown), keyEquivalent: "")
        showCountdownMenuItem.target = self
        updateShowCountdownState()
        menu.addItem(showCountdownMenuItem)

        strictModeMenuItem = NSMenuItem(title: localized("strictMode"), action: #selector(toggleStrictMode), keyEquivalent: "")
        strictModeMenuItem.target = self
        updateStrictModeMenuState()
        menu.addItem(strictModeMenuItem)

        let skipDelayItem = NSMenuItem(title: localized("skipDelay"), action: nil, keyEquivalent: "")
        let skipDelaySubmenu = NSMenu()
        skipDelayMenuItems.removeAll()
        for delay in BreakSkipSettings.supportedDelaySeconds {
            let title = delay == 0 ? localized("skipDelayNone") : "\(delay) \(localized("seconds"))"
            let item = NSMenuItem(title: title, action: #selector(selectSkipDelay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = delay
            skipDelaySubmenu.addItem(item)
            skipDelayMenuItems.append(item)
        }
        updateSkipDelayMenuStates()
        skipDelayItem.submenu = skipDelaySubmenu
        menu.addItem(skipDelayItem)

        let preBreakItem = NSMenuItem(title: localized("preBreakHeadsUp"), action: nil, keyEquivalent: "")
        let preBreakSubmenu = NSMenu()
        preBreakLeadTimeMenuItems.removeAll()
        for option in PreBreakLeadTime.allCases {
            let item = NSMenuItem(
                title: preBreakLeadTimeTitle(option),
                action: #selector(selectPreBreakLeadTime(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = option.rawValue
            item.state = (preBreakLeadTime == option) ? .on : .off
            preBreakSubmenu.addItem(item)
            preBreakLeadTimeMenuItems.append(item)
        }
        preBreakItem.submenu = preBreakSubmenu
        menu.addItem(preBreakItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: localized("about"), action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: localized("quit"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)

        statusBarItem.menu = menu
    }
    
    private func setupSystemNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for name in [NSNotification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(systemClockOrTimeZoneChanged), name: name, object: nil)
        }
        
        // Listen for system sleep/wake notifications
        notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        
        notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        
        // Listen for screen sleep/wake notifications
        notificationCenter.addObserver(
            self,
            selector: #selector(screensDidSleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        
        notificationCenter.addObserver(
            self,
            selector: #selector(screensDidWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        
        // Listen for screen lock/unlock notifications (closer to screensaver functionality)
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidLock),
            name: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
        
        // Listen for screensaver notifications
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(screensaverDidStart),
            name: NSNotification.Name("com.apple.screensaver.didstart"),
            object: nil
        )
        
        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(screensaverDidStop),
            name: NSNotification.Name("com.apple.screensaver.didstop"),
            object: nil
        )
    }
    
    private func setupModeMenu() {
        let modeLabel = NSMenuItem(title: localized("mode"), action: nil, keyEquivalent: "")
        modeLabel.isEnabled = false
        menu.addItem(modeLabel)
        
        // Default 20-20-20 Mode
        let defaultModeItem = NSMenuItem(title: localized("defaultMode"), action: #selector(selectDefaultMode), keyEquivalent: "")
        defaultModeItem.target = self
        defaultModeItem.state = !isCustomMode ? .on : .off
        defaultModeItem.representedObject = "defaultMode" // Add identifier
        menu.addItem(defaultModeItem)
        modeMenuItems.append(defaultModeItem)
        
        // Custom Mode
        let customModeItem = NSMenuItem(title: localized("customMode"), action: #selector(selectCustomMode), keyEquivalent: "")
        customModeItem.target = self
        customModeItem.state = isCustomMode ? .on : .off
        customModeItem.representedObject = "customMode" // Add identifier
        menu.addItem(customModeItem)
        modeMenuItems.append(customModeItem)
        
        // Add dynamic sub-items if custom mode is selected
        if isCustomMode {
            addCustomModeSubItems()
        }
    }
    
    private func addCustomModeSubItems() {
        // Find the index of custom mode item
        guard let customModeIndex = menu.items.firstIndex(where: { $0.title == localized("customMode") }) else { return }
        
        // Work Duration Item with current value display
        let currentWorkMinutes = currentWorkDuration / 60
        let workDurationItem = NSMenuItem(title: "    \(localized("screenUsage")): \(currentWorkMinutes) \(localized("minutes"))", action: nil, keyEquivalent: "")
        let workDurationSubmenu = NSMenu()
        
        let workDurations = [10, 15, 20, 25, 30, 35, 40, 45, 50, 60] // minutes
        for duration in workDurations {
            let item = NSMenuItem(title: "\(duration) \(localized("minutes"))", action: #selector(selectWorkDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = duration
            item.state = (currentWorkDuration == duration * 60) ? .on : .off
            workDurationSubmenu.addItem(item)
            workDurationMenuItems.append(item)
        }
        
        workDurationItem.submenu = workDurationSubmenu
        menu.insertItem(workDurationItem, at: customModeIndex + 1)
        
        // Break Duration Item with current value display
        let breakDisplayText: String
        if currentBreakDuration >= 60 {
            let minutes = currentBreakDuration / 60
            breakDisplayText = "\(minutes) \(localized("minutes"))"
        } else {
            breakDisplayText = "\(currentBreakDuration) \(localized("seconds"))"
        }
        let breakDurationItem = NSMenuItem(title: "    \(localized("screenBreak")): \(breakDisplayText)", action: nil, keyEquivalent: "")
        let breakDurationSubmenu = NSMenu()
        
        let breakDurations = [10, 20, 30, 60, 120, 180, 300, 600] // seconds: 10s, 20s, 30s, 1min, 2min, 3min, 5min, 10min
        for duration in breakDurations {
            let displayText: String
            if duration >= 60 {
                let minutes = duration / 60
                displayText = "\(minutes) \(localized("minutes"))"
            } else {
                displayText = "\(duration) \(localized("seconds"))"
            }
            let item = NSMenuItem(title: displayText, action: #selector(selectBreakDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = duration
            item.state = (currentBreakDuration == duration) ? .on : .off
            breakDurationSubmenu.addItem(item)
            breakDurationMenuItems.append(item)
        }
        
        breakDurationItem.submenu = breakDurationSubmenu
        menu.insertItem(breakDurationItem, at: customModeIndex + 2)

        // Postpone Limit Item
        let currentPostponeMinutes = customPostponeLimitMinutes
        let postponeLimitItem = NSMenuItem(title: "    \(localized("postponeLimit")): \(currentPostponeMinutes) \(localized("minutes"))", action: nil, keyEquivalent: "")
        let postponeLimitSubmenu = NSMenu()

        let postponeLimits = [5, 10] // minutes
        for limit in postponeLimits {
            let item = NSMenuItem(title: "\(limit) \(localized("minutes"))", action: #selector(selectPostponeLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = limit
            item.state = (currentPostponeMinutes == limit) ? .on : .off
            postponeLimitSubmenu.addItem(item)
            postponeLimitMenuItems.append(item)
        }

        postponeLimitItem.submenu = postponeLimitSubmenu
        menu.insertItem(postponeLimitItem, at: customModeIndex + 3)
    }

    private func removeCustomModeSubItems() {
        // Clear sub-menu items arrays
        workDurationMenuItems.removeAll()
        breakDurationMenuItems.removeAll()
        postponeLimitMenuItems.removeAll()

        // Remove the main duration items from menu
        let itemsToRemove = menu.items.filter {
            $0.title.hasPrefix("    \(localized("screenUsage"))") ||
            $0.title.hasPrefix("    \(localized("screenBreak"))") ||
            $0.title.hasPrefix("    \(localized("postponeLimit"))")
        }
        for item in itemsToRemove {
            menu.removeItem(item)
        }
    }
    
    private func updateCustomModeSubItems() {
        if isCustomMode {
            removeCustomModeSubItems()
            addCustomModeSubItems()
        }
    }

    private func loadClockTime(forKey key: String, defaultValue: ClockTime) -> ClockTime {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        let minutes = min(23 * 60 + 59, max(0, UserDefaults.standard.integer(forKey: key)))
        return ClockTime(minutesAfterMidnight: minutes)
    }

    private func cleanupLegacyNightOverrideDefaults() {
        UserDefaults.standard.removeObject(forKey: NightOverrideDefaults.legacyOverrideUntil)
        UserDefaults.standard.removeObject(forKey: NightOverrideDefaults.legacyTestingExit)
    }

    private func loadNightOverrideState() -> NightOverrideState? {
        guard let grantedAt = UserDefaults.standard.object(forKey: NightOverrideDefaults.grantedAt) as? Date,
              let until = UserDefaults.standard.object(forKey: NightOverrideDefaults.until) as? Date,
              let reasonRawValue = UserDefaults.standard.string(forKey: NightOverrideDefaults.reason),
              let reason = NightOverrideReason(rawValue: reasonRawValue),
              let nightKey = UserDefaults.standard.string(forKey: NightOverrideDefaults.nightKey) else {
            clearNightOverrideState()
            return nil
        }

        return NightOverrideState(
            grantedAt: grantedAt,
            until: until,
            reason: reason,
            nightKey: nightKey,
            overrideNumberForNight: max(1, UserDefaults.standard.integer(forKey: NightOverrideDefaults.numberForNight))
        )
    }

    private func saveNightOverrideState() {
        guard let state = nightOverrideState else {
            clearNightOverrideState()
            return
        }

        UserDefaults.standard.set(state.grantedAt, forKey: NightOverrideDefaults.grantedAt)
        UserDefaults.standard.set(state.until, forKey: NightOverrideDefaults.until)
        UserDefaults.standard.set(state.reason.rawValue, forKey: NightOverrideDefaults.reason)
        UserDefaults.standard.set(state.nightKey, forKey: NightOverrideDefaults.nightKey)
        UserDefaults.standard.set(state.overrideNumberForNight, forKey: NightOverrideDefaults.numberForNight)
    }

    private func clearNightOverrideState() {
        UserDefaults.standard.removeObject(forKey: NightOverrideDefaults.grantedAt)
        UserDefaults.standard.removeObject(forKey: NightOverrideDefaults.until)
        UserDefaults.standard.removeObject(forKey: NightOverrideDefaults.reason)
        UserDefaults.standard.removeObject(forKey: NightOverrideDefaults.nightKey)
        UserDefaults.standard.removeObject(forKey: NightOverrideDefaults.numberForNight)
    }

    private func loadTemporaryDisableState() -> TemporaryDisableState? {
        guard let startedAt = UserDefaults.standard.object(forKey: TemporaryDisableDefaults.startedAt) as? Date,
              let until = UserDefaults.standard.object(forKey: TemporaryDisableDefaults.until) as? Date,
              until > startedAt else {
            clearTemporaryDisableState()
            return nil
        }

        return TemporaryDisableState(startedAt: startedAt, until: until)
    }

    private func saveTemporaryDisableState() {
        guard let state = temporaryDisableState else {
            clearTemporaryDisableState()
            return
        }

        UserDefaults.standard.set(state.startedAt, forKey: TemporaryDisableDefaults.startedAt)
        UserDefaults.standard.set(state.until, forKey: TemporaryDisableDefaults.until)
    }

    private func clearTemporaryDisableState() {
        UserDefaults.standard.removeObject(forKey: TemporaryDisableDefaults.startedAt)
        UserDefaults.standard.removeObject(forKey: TemporaryDisableDefaults.until)
    }

    private func nightOverrideCount(for nightKey: String) -> Int {
        guard UserDefaults.standard.string(forKey: NightOverrideDefaults.countNightKey) == nightKey else {
            return 0
        }
        return max(0, UserDefaults.standard.integer(forKey: NightOverrideDefaults.countForNight))
    }

    private func saveNightOverrideCount(_ count: Int, nightKey: String) {
        UserDefaults.standard.set(nightKey, forKey: NightOverrideDefaults.countNightKey)
        UserDefaults.standard.set(max(0, count), forKey: NightOverrideDefaults.countForNight)
    }

    private func setupNightRestrictionMenu() {
        nightRestrictionMenuItem = NSMenuItem(title: localized("nightRestriction"), action: nil, keyEquivalent: "")
        nightRestrictionMenuItem.submenu = buildNightRestrictionSubmenu()
        menu.addItem(nightRestrictionMenuItem)
    }

    private func rebuildNightRestrictionMenu() {
        guard nightRestrictionMenuItem != nil else { return }
        nightRestrictionMenuItem.title = localized("nightRestriction")
        nightRestrictionMenuItem.submenu = buildNightRestrictionSubmenu()
    }

    private func buildNightRestrictionSubmenu() -> NSMenu {
        enforceNightScheduleOrder()

        let submenu = NSMenu()

        let enabledItem = NSMenuItem(title: localized("nightRestrictionEnabled"), action: #selector(toggleNightRestriction), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = nightRestrictionSettings.isEnabled ? .on : .off
        submenu.addItem(enabledItem)

        submenu.addItem(NSMenuItem.separator())

        let windDownItem = NSMenuItem(
            title: "\(localized("nightWindDownStart")): \(nightRestrictionSettings.windDownStart.displayString)",
            action: nil,
            keyEquivalent: ""
        )
        windDownItem.submenu = buildTimeSelectionMenu(
            options: timeOptions(from: 18 * 60, through: 23 * 60),
            selected: nightRestrictionSettings.windDownStart,
            action: #selector(selectNightWindDownStart(_:))
        )
        submenu.addItem(windDownItem)

        var lockOptions = timeOptions(from: 18 * 60 + 30, through: 23 * 60 + 30)
            .filter { $0 > nightRestrictionSettings.windDownStart }
        if !lockOptions.contains(nightRestrictionSettings.lockStart),
           nightRestrictionSettings.lockStart > nightRestrictionSettings.windDownStart {
            lockOptions.append(nightRestrictionSettings.lockStart)
            lockOptions.sort()
        }
        let lockItem = NSMenuItem(
            title: "\(localized("nightLockStart")): \(nightRestrictionSettings.lockStart.displayString)",
            action: nil,
            keyEquivalent: ""
        )
        lockItem.submenu = buildTimeSelectionMenu(
            options: lockOptions,
            selected: nightRestrictionSettings.lockStart,
            action: #selector(selectNightLockStart(_:))
        )
        submenu.addItem(lockItem)

        let unlockItem = NSMenuItem(
            title: "\(localized("nightUnlockTime")): \(nightRestrictionSettings.unlockTime.displayString)",
            action: nil,
            keyEquivalent: ""
        )
        unlockItem.submenu = buildTimeSelectionMenu(
            options: timeOptions(from: 5 * 60, through: 10 * 60),
            selected: nightRestrictionSettings.unlockTime,
            action: #selector(selectNightUnlockTime(_:))
        )
        submenu.addItem(unlockItem)

        submenu.addItem(NSMenuItem.separator())

        let rhythmItem = NSMenuItem(title: nightRhythmSummaryTitle(), action: nil, keyEquivalent: "")
        rhythmItem.submenu = buildNightRhythmSubmenu()
        submenu.addItem(rhythmItem)

        return submenu
    }

    private func buildTimeSelectionMenu(options: [ClockTime], selected: ClockTime, action: Selector) -> NSMenu {
        let submenu = NSMenu()
        for time in options {
            let item = NSMenuItem(title: time.displayString, action: action, keyEquivalent: "")
            item.target = self
            item.tag = time.minutesAfterMidnight
            item.state = (time == selected) ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    private func timeOptions(from startMinute: Int, through endMinute: Int, step: Int = 30) -> [ClockTime] {
        guard startMinute <= endMinute else { return [] }
        return stride(from: startMinute, through: endMinute, by: step).map {
            ClockTime(minutesAfterMidnight: $0)
        }
    }

    private func enforceNightScheduleOrder() {
        if nightRestrictionSettings.lockStart <= nightRestrictionSettings.windDownStart {
            let adjustedLockMinute = min(23 * 60 + 30, nightRestrictionSettings.windDownStart.minutesAfterMidnight + 60)
            nightRestrictionSettings.lockStart = ClockTime(minutesAfterMidnight: adjustedLockMinute)
        }
    }

    private func nightRhythmSummaryTitle() -> String {
        let base = formatDurationForMenu(currentWorkDuration)
        return "\(localized("nightRhythmToday")): \(base) -> \(localized("nightDisabled"))"
    }

    private func buildNightRhythmSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let base = formatDurationForMenu(currentWorkDuration)
        let stages = NightRestrictionPolicy.windDownLimits(baseWorkDurationSeconds: currentWorkDuration)
            .map(formatDurationForMenu)

        submenu.addItem(disabledMenuItem("\(localized("nightRhythmCurrent")): \(base)"))
        submenu.addItem(NSMenuItem.separator())

        for (index, stage) in stages.enumerated() {
            submenu.addItem(disabledMenuItem("\(localized("nightRhythmStage")) \(index + 1): \(stage)"))
        }

        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(disabledMenuItem("\(localized("nightRhythmLockedAfter")): \(localized("nightDisabled"))"))
        return submenu
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func formatDurationForMenu(_ seconds: Int) -> String {
        "\(max(1, seconds / 60)) \(localized("minutes"))"
    }

    @objc private func toggleNightRestriction() {
        nightRestrictionSettings.isEnabled.toggle()
        saveSettings()
        rebuildNightRestrictionMenu()
        _ = applyNightRestrictionState(reason: "night_setting_toggle")
        updateMenuTimer()
        updateStatusBarTitle()
        rescheduleCountdown()
    }

    @objc private func selectNightWindDownStart(_ sender: NSMenuItem) {
        nightRestrictionSettings.windDownStart = ClockTime(minutesAfterMidnight: sender.tag)
        enforceNightScheduleOrder()
        saveSettings()
        rebuildNightRestrictionMenu()
        _ = applyNightRestrictionState(reason: "night_wind_down_changed")
        updateMenuTimer()
        updateStatusBarTitle()
        rescheduleCountdown()
    }

    @objc private func selectNightLockStart(_ sender: NSMenuItem) {
        let selected = ClockTime(minutesAfterMidnight: sender.tag)
        guard selected > nightRestrictionSettings.windDownStart else { return }

        nightRestrictionSettings.lockStart = selected
        saveSettings()
        rebuildNightRestrictionMenu()
        _ = applyNightRestrictionState(reason: "night_lock_start_changed")
        updateMenuTimer()
        updateStatusBarTitle()
        rescheduleCountdown()
    }

    @objc private func selectNightUnlockTime(_ sender: NSMenuItem) {
        nightRestrictionSettings.unlockTime = ClockTime(minutesAfterMidnight: sender.tag)
        saveSettings()
        rebuildNightRestrictionMenu()
        _ = applyNightRestrictionState(reason: "night_unlock_changed")
        updateMenuTimer()
        updateStatusBarTitle()
        rescheduleCountdown()
    }

    @objc private func statusBarButtonClicked() {
        statusBarItem.menu = menu
        statusBarItem.button?.performClick(nil)
    }

    @objc private func toggleTemporaryDisable() {
        if isTemporaryDisableActive {
            finishTemporaryDisable(reason: "manual_end", startFreshWorkSession: true)
        } else {
            beginTemporaryDisable(reason: "manual_start")
        }
    }
    
    @objc private func triggerTestBreak() {
        // 记录当前工作会话（如果有）
        if let startTime = workSessionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            logManager.logWorkPaused(duration: elapsed, reason: "manual_test_break")
        }

        // 使用新的事件记录器
        eventRecorder.endWorkSession()

        countdownScheduler.cancel()
        cancelInputDeferral()
        showBreakOverlay(bypassInputDeferral: true)
    }
    
    @objc private func showHealthStats() {
        // 如果窗口已经存在，就激活它而不是创建新的
        if let existingWindow = healthStatsWindow {
            if existingWindow.isVisible {
                existingWindow.reloadData()
                existingWindow.makeKeyAndOrderFront(nil)
                return
            } else {
                // 窗口存在但不可见，清理引用
                healthStatsWindow = nil
            }
        }
        
        // 创建新的统计窗口
        let statsWindow = StatsDashboardWindow()
        statsWindow.setLocalizer(localized)
        healthStatsWindow = statsWindow
        
        // 设置窗口代理以在关闭时清理引用
        statsWindow.delegate = self
        
        // 显示窗口
        statsWindow.makeKeyAndOrderFront(nil)

        // 确保窗口获得焦点
        NSApp.activate(ignoringOtherApps: true)
        
        print("📊 统计窗口已创建并显示")
    }

    @objc private func showAbout() {
        print("📖 showAbout 被调用")

        // 读取版本历史 JSON 文件
        guard let versionData = loadVersionHistory() else {
            print("❌ 无法加载版本历史")
            // 使用默认信息显示
            showAboutPanelWithDefaults()
            return
        }

        print("✅ 成功加载版本历史数据")

        // 构建显示内容
        let appName = versionData["app_name"] as? String ?? AppIdentity.displayName
        let version = versionData["current_version"] as? String ?? "1.5.0"

        var creditsText = ""

        // 添加当前版本信息
        if let versions = versionData["versions"] as? [[String: Any]],
           let currentVersionInfo = versions.first,
           let versionNumber = currentVersionInfo["version"] as? String,
           let date = currentVersionInfo["date"] as? String,
           let changes = currentVersionInfo["changes"] as? [String] {

            creditsText += "Version \(versionNumber) - \(date)\n\n"
            creditsText += "What's New:\n"
            for change in changes {
                creditsText += "• \(change)\n"
            }
            creditsText += "\n"
        }

        // 添加作者信息
        if let author = versionData["author"] as? [String: String],
           let name = author["name"],
           let email = author["email"],
           let github = author["github"] {
            creditsText += "Author: \(name)\n"
            creditsText += "Email: \(email)\n"
            creditsText += "GitHub: \(github)\n"
        }

        print("📝 Credits 内容:\n\(creditsText)")

        // 创建 attributed string
        let credits = NSAttributedString(string: creditsText, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ])

        // 显示标准 About Panel
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: appName,
            .applicationVersion: version,
            .version: version,
            .credits: credits
        ]

        // 激活应用确保窗口显示
        NSApp.activate(ignoringOtherApps: true)

        print("🪟 准备显示 About Panel")
        NSApp.orderFrontStandardAboutPanel(options: options)
        print("✅ About Panel 已调用显示")
    }

    private func loadVersionHistory() -> [String: Any]? {
        // 方法 1: 尝试从资源包加载
        if let bundle = Bundle(for: type(of: self)).url(forResource: "EyeGuard_EyeGuard", withExtension: "bundle"),
           let resourceBundle = Bundle(url: bundle),
           let jsonPath = resourceBundle.path(forResource: "version-history", ofType: "json", inDirectory: "Resources") {

            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                if let dict = json as? [String: Any] {
                    print("✅ 成功从资源包加载版本历史: \(jsonPath)")
                    return dict
                }
            } catch {
                print("⚠️ 解析版本历史失败 (\(jsonPath)): \(error)")
            }
        }

        // 方法 2: 尝试从主 bundle 的 Resources 目录加载
        if let jsonPath = Bundle.main.path(forResource: "version-history", ofType: "json", inDirectory: "Resources") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                if let dict = json as? [String: Any] {
                    print("✅ 成功从主 bundle 加载版本历史: \(jsonPath)")
                    return dict
                }
            } catch {
                print("⚠️ 解析版本历史失败 (\(jsonPath)): \(error)")
            }
        }

        // 方法 3: 尝试从主 bundle 根目录加载
        if let jsonPath = Bundle.main.path(forResource: "version-history", ofType: "json") {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
                let json = try JSONSerialization.jsonObject(with: data, options: [])
                if let dict = json as? [String: Any] {
                    print("✅ 成功从主 bundle 根目录加载版本历史: \(jsonPath)")
                    return dict
                }
            } catch {
                print("⚠️ 解析版本历史失败 (\(jsonPath)): \(error)")
            }
        }

        print("⚠️ 未找到版本历史文件")
        return nil
    }

    private func showAboutPanelWithDefaults() {
        print("⚠️ 使用默认信息显示 About Panel")

        // 使用默认信息显示
        let defaultCredits = NSAttributedString(
            string: "EyeGuard\n\nAuthor: Javen Fang\nEmail: javen.out@gmail.com\nGitHub: JavenGroup/TwentyGuard",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor
            ]
        )

        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppIdentity.displayName,
            .applicationVersion: "1.5.0",
            .version: "1.5.0",
            .credits: defaultCredits
        ]

        // 激活应用确保窗口显示
        NSApp.activate(ignoringOtherApps: true)

        NSApp.orderFrontStandardAboutPanel(options: options)
        print("✅ About Panel（默认）已调用显示")
    }

    @objc private func toggleLoginItem() {
        let currentState = UserDefaults.standard.bool(forKey: "loginItemEnabled")
        let newState = !currentState
        UserDefaults.standard.set(newState, forKey: "loginItemEnabled")
        updateLoginItemState()
        
        if newState {
            addToLoginItems()
        } else {
            removeFromLoginItems()
        }
    }
    
    private func isLoginItemEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "loginItemEnabled")
    }
    
    private func updateLoginItemState() {
        let isEnabled = isLoginItemEnabled()
        loginItemMenuItem.state = isEnabled ? .on : .off
    }
    
    @objc private func toggleShowCountdown() {
        showCountdownInStatusBar.toggle()
        updateShowCountdownState()
        refreshCountdownDisplayAndTimer()
        saveSettings()
    }
    
    private func updateShowCountdownState() {
        showCountdownMenuItem.state = showCountdownInStatusBar ? .on : .off
    }

    @objc private func toggleStrictMode() {
        breakSkipSettings.isStrictMode.toggle()
        updateStrictModeMenuState()
        saveSettings()
        updateBreakOverlaysSkipState()
    }

    private func updateStrictModeMenuState() {
        strictModeMenuItem?.state = breakSkipSettings.isStrictMode ? .on : .off
    }

    @objc private func selectSkipDelay(_ sender: NSMenuItem) {
        breakSkipSettings.skipDelaySeconds = max(0, sender.tag)
        updateSkipDelayMenuStates()
        saveSettings()
        updateBreakOverlaysSkipState()
    }

    private func updateSkipDelayMenuStates() {
        for item in skipDelayMenuItems {
            item.state = (item.tag == breakSkipSettings.skipDelaySeconds) ? .on : .off
        }
    }
    
    private func addToLoginItems() {
        let appPath = Bundle.main.bundlePath
        guard !appPath.isEmpty else { return }
        
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.register()
        } else {
            let script = """
            tell application "System Events"
                make login item at end with properties {path:"\(appPath)", hidden:false}
            end tell
            """
            
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(nil)
            }
        }
    }
    
    private func removeFromLoginItems() {
        let appPath = Bundle.main.bundlePath
        guard !appPath.isEmpty else { return }
        
        if #available(macOS 13.0, *) {
            try? SMAppService.mainApp.unregister()
        } else {
            let script = """
            tell application "System Events"
                delete login item "\(URL(fileURLWithPath: appPath).lastPathComponent)"
            end tell
            """
            
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(nil)
            }
        }
    }
    
    @objc private func quitApp() {
        // 记录当前会话状态
        if let startTime = workSessionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            logManager.logWorkPaused(duration: elapsed, reason: "app_terminated")
        }

        if let startTime = breakSessionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            logManager.logBreakCompleted(actualDuration: elapsed, expectedDuration: currentBreakDuration)
            eventRecorder.endBreakSession()
        }

        // 使用新的事件记录器
        eventRecorder.recordAppTermination()
        
        countdownScheduler.cancel()
        stateSnapshotTimer?.invalidate()
        screenCaptureMonitor.stop()
        meetingCallMonitor.stop()
        calendarEventMonitor.stop()
        focusAppMonitor.stop()
        idleMonitor.stop()
        dismissPreBreakHUD()
        for overlay in nightLockOverlays {
            overlay.hideOverlay()
        }
        nightLockOverlays.removeAll()
        
        // Clean up notification observers
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        
        NSApplication.shared.terminate(nil)
    }
    
    @objc private func selectDefaultMode() {
        if isCustomMode {
            removeCustomModeSubItems()
        }
        isCustomMode = false
        currentWorkDuration = 20 * 60
        currentBreakDuration = 20
        maxTotalPostponeTime = 5 * 60  // Default mode: 5 minutes postpone limit

        eventRecorder.recordModeChange(mode: "default", workDuration: currentWorkDuration, breakDuration: currentBreakDuration)

        saveSettings()
        updateModeMenuStates()
        rebuildNightRestrictionMenu()
        restartWorkTimer()
    }
    
    @objc private func selectCustomMode() {
        if !isCustomMode {
            isCustomMode = true
            currentWorkDuration = customWorkDuration
            currentBreakDuration = customBreakDuration
            maxTotalPostponeTime = TimeInterval(customPostponeLimitMinutes * 60)
            
            eventRecorder.recordModeChange(mode: "custom", workDuration: currentWorkDuration, breakDuration: currentBreakDuration)
            
            addCustomModeSubItems()
            saveSettings()
            updateModeMenuStates()
            rebuildNightRestrictionMenu()
            restartWorkTimer()
        }
    }
    
    @objc private func selectWorkDuration(_ sender: NSMenuItem) {
        currentWorkDuration = sender.tag * 60
        customWorkDuration = currentWorkDuration
        updateCustomModeSubItems()
        updateModeMenuStates()
        saveSettings()
        rebuildNightRestrictionMenu()
        restartWorkTimer()
    }
    
    @objc private func selectBreakDuration(_ sender: NSMenuItem) {
        currentBreakDuration = sender.tag
        customBreakDuration = currentBreakDuration
        updateCustomModeSubItems()
        updateModeMenuStates()
        saveSettings()
        rescheduleCountdown()
    }

    @objc private func selectPostponeLimit(_ sender: NSMenuItem) {
        customPostponeLimitMinutes = sender.tag
        maxTotalPostponeTime = TimeInterval(customPostponeLimitMinutes * 60)
        updateCustomModeSubItems()
        saveSettings()
    }

    private func updateModeMenuStates() {
        // Update mode states based on representedObject instead of array index
        for item in modeMenuItems {
            if let identifier = item.representedObject as? String {
                switch identifier {
                case "defaultMode":
                    item.state = !isCustomMode ? .on : .off
                case "customMode":
                    item.state = isCustomMode ? .on : .off
                default:
                    break
                }
            }
        }
        
        // Update work duration states (only when custom mode is active)
        for item in workDurationMenuItems {
            item.state = (currentWorkDuration == item.tag * 60) ? .on : .off
        }
        
        // Update break duration states (only when custom mode is active)
        for item in breakDurationMenuItems {
            item.state = (currentBreakDuration == item.tag) ? .on : .off
        }
    }
    
    private func restartWorkTimer() {
        guard displaysAreActive else { rescheduleCountdown(); return }
        cancelInputDeferral()
        if applyNightRestrictionState(reason: "restart_work_timer") {
            rescheduleCountdown()
            return
        }

        if manualBreakSettings.isManualOnlyMode {
            enterManualOnlyIdleState()
            return
        }

        // 停止当前工作会话（如果有）
        if let startTime = workSessionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            logManager.logWorkPaused(duration: elapsed, reason: "manual_restart")
        }
        
        // 开始新的工作会话
        workSessionStartTime = Date()
        breakSessionStartTime = nil
        postponeStartTime = nil
        postponeDuration = 0
        totalPostponedTime = 0  // 重置累计推迟时间
        isPausedBySystemEvent = false

        updateStatusBarTitle()
        updateMenuTimer()
        saveCurrentSessionState()

        // 使用新的事件记录器
        eventRecorder.startWorkSession(duration: effectiveWorkDuration)
        
        // 启动UI更新计时器
        rescheduleCountdown()
    }
    
    private func startWorkTimer(forceFreshSession: Bool = false) {
        guard displaysAreActive else { rescheduleCountdown(); return }
        if applyNightRestrictionState(reason: "start_work_timer") {
            rescheduleCountdown()
            return
        }

        if manualBreakSettings.isManualOnlyMode {
            enterManualOnlyIdleState()
            return
        }

        if forceFreshSession {
            cancelInputDeferral()
            let now = Date()
            let hadPostponeState = postponeStartTime != nil || postponeDuration > 0 || totalPostponedTime > 0
            let nextState = SessionState(
                workStartTime: workSessionStartTime,
                breakStartTime: breakSessionStartTime,
                postponeStartTime: postponeStartTime,
                postponeDuration: postponeDuration,
                totalPostponedTime: totalPostponedTime,
                currentWorkDuration: currentWorkDuration,
                currentBreakDuration: currentBreakDuration,
                isCustomMode: isCustomMode,
                lastSaved: now,
                pausedBySystemEvent: false
            ).completedBreak(now: now)

            workSessionStartTime = nextState.workStartTime
            breakSessionStartTime = nextState.breakStartTime
            postponeStartTime = nextState.postponeStartTime
            postponeDuration = nextState.postponeDuration
            totalPostponedTime = nextState.totalPostponedTime
            isPausedBySystemEvent = false

            logSessionDebug("break_completed_started_fresh_work_session", context: [
                "work_start_time": debugTimestamp(workSessionStartTime),
                "cleared_postpone_state": "\(hadPostponeState)"
            ])
            eventRecorder.recordTimerReset(reason: "fresh_start")
            eventRecorder.startWorkSession(duration: effectiveWorkDuration)
        } else {
            // 如果在推迟期间，不要重置工作会话
            if !isPostponeActive {
                // 如果还没有开始工作会话，则开始一个新的
                if workSessionStartTime == nil {
                    workSessionStartTime = Date()
                    isPausedBySystemEvent = false
                    eventRecorder.recordTimerReset(reason: "fresh_start")
                    eventRecorder.startWorkSession(duration: effectiveWorkDuration)
                }
            }
        }
        
        breakSessionStartTime = nil
        updateStatusBarTitle()
        updateMenuTimer()
        saveCurrentSessionState()
        
        // 启动UI更新计时器
        rescheduleCountdown()
    }
    
    private func updateWorkTimer() {
        if applyNightRestrictionState(reason: "work_timer_tick") {
            return
        }

        // Display updates are scheduled independently of these due actions.

        // 检查推迟时间是否结束
        if postponeStartTime != nil && postponeTimeRemaining <= 0 {
            // 推迟时间结束，清除推迟状态，开始正常休息
            print("⏰ Postpone time finished, showing break overlay")
            countdownScheduler.cancel()
            postponeStartTime = nil
            postponeDuration = 0
            showBreakOverlay()
        }
        // 检查工作时间是否已完成（添加重入保护）
        else if workTimeRemaining <= 0 && !isCompletingWorkSession {
            print("⏰ Work time finished (remaining: \(workTimeRemaining)), completing work session")
            completeWorkSession()
        }
    }
    
    private func completeWorkSession() {
        // 设置标志防止重入
        isCompletingWorkSession = true
        
        // 首先停止定时器，无论后续操作是否成功
        countdownScheduler.cancel()

        if applyNightRestrictionState(reason: "complete_work_session") {
            isCompletingWorkSession = false
            rescheduleCountdown()
            return
        }
        
        if let startTime = workSessionStartTime {
            let actualDuration = Date().timeIntervalSince(startTime)
            logManager.logWorkCompleted(duration: actualDuration)
        }
        
        // 尝试显示休息窗口
        showBreakOverlay()
        
        // 清除标志
        isCompletingWorkSession = false
    }
    
    private func updateStatusBarTitle(now: Date = Date(), status: NightRestrictionStatus? = nil) {
        guard let button = statusBarItem.button else { return }
        let nightStatus = status ?? currentNightStatus(now: now)
        let title: String
        if nightStatus.isOverrideActive, let state = nightOverrideState {
            title = " " + localized("nightOverrideActiveStatus") + " " + formatStatusBarTime(CountdownTiming.secondsRemaining(until: state.until, now: now))
        } else if nightStatus.isLocked {
            title = " " + localized("nightLockedStatus")
        } else if isTemporaryDisableActive {
            title = " " + localized("temporaryDisableActiveStatus") + " " + formatStatusBarTime(temporaryDisableRemainingSeconds)
        } else if isSmartPaused {
            title = " " + localized("smartPauseStatusBar")
        } else if isWaitingForInputDeferral {
            title = " " + localized("smartPauseWaitingStatusBar")
        } else if manualBreakSettings.isManualOnlyMode {
            title = " " + localized("manualBreakStatusBar")
        } else if showCountdownInStatusBar {
            if let start = postponeStartTime {
                title = " " + formatStatusBarTime(CountdownTiming.secondsRemaining(until: start.addingTimeInterval(postponeDuration), now: now))
            } else {
                let remaining = remainingWorkTime(at: now, status: nightStatus)
                if workSessionStartTime != nil, remaining > 60 {
                    title = " \(Int(ceil(remaining / 60))) \(localized("minutes"))"
                } else {
                    title = " " + formatStatusBarTime(Int(ceil(remaining)))
                }
            }
        } else {
            title = ""
        }
        if button.title != title { button.title = title }
    }
    
    private func loadStatusBarIcon() -> NSImage? {
        // Try different ways to load the custom icon for SPM
        
        // Method 1: Try to load from module bundle with high-res support
        if let bundle = Bundle(for: type(of: self)).url(forResource: "EyeGuard_EyeGuard", withExtension: "bundle"),
           let resourceBundle = Bundle(url: bundle) {
            
            // Create an NSImage and add both 1x and 2x representations
            let statusIcon = NSImage(size: NSSize(width: 16, height: 16))
            
            // Load 1x image
            if let path1x = resourceBundle.path(forResource: "statusbar_icon", ofType: "png", inDirectory: "Resources"),
               let image1x = NSImage(contentsOfFile: path1x) {
                let rep1x = image1x.representations.first
                rep1x?.size = NSSize(width: 16, height: 16)
                if let rep1x = rep1x {
                    statusIcon.addRepresentation(rep1x)
                }
            }
            
            // Load 2x image
            if let path2x = resourceBundle.path(forResource: "statusbar_icon@2x", ofType: "png", inDirectory: "Resources"),
               let image2x = NSImage(contentsOfFile: path2x) {
                let rep2x = image2x.representations.first
                rep2x?.size = NSSize(width: 16, height: 16) // Logical size stays 16x16
                if let rep2x = rep2x {
                    statusIcon.addRepresentation(rep2x)
                }
            }
            
            return statusIcon.representations.count > 0 ? statusIcon : nil
        }
        
        // Method 2: Try main bundle Resources directory
        if let resourcePath = Bundle.main.path(forResource: "statusbar_icon", ofType: "png", inDirectory: "Resources"),
           let statusIcon = NSImage(contentsOfFile: resourcePath) {
            statusIcon.size = NSSize(width: 16, height: 16)
            return statusIcon
        }
        
        // Method 3: Try main bundle root
        if let resourcePath = Bundle.main.path(forResource: "statusbar_icon", ofType: "png"),
           let statusIcon = NSImage(contentsOfFile: resourcePath) {
            statusIcon.size = NSSize(width: 16, height: 16)
            return statusIcon
        }
        
        return nil
    }
    
    
    private func formatStatusBarTime(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
    
    private func formatWorkTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%@: %02d:%02d", localized("screenUsage"), minutes, secs)
    }

    private func currentNightStatus(now: Date = Date()) -> NightRestrictionStatus {
        nightPolicy.status(
            now: now,
            baseWorkDurationSeconds: currentWorkDuration,
            settings: nightRestrictionSettings,
            overrideUntil: nightOverrideState?.until
        )
    }

    private func clearExpiredNightOverride(now: Date = Date()) {
        guard let state = nightOverrideState, !nightOverridePolicy.isActive(state, now: now) else { return }
        eventRecorder.recordNightOverrideExpired(state: state)
        nightOverrideState = nil
        saveNightOverrideState()
    }

    private func restoreTemporaryDisableIfNeeded() -> Bool {
        guard let state = temporaryDisableState else { return false }

        let status = currentNightStatus()
        if temporaryDisablePolicy.shouldInterruptActiveDisable(for: status) {
            finishTemporaryDisable(reason: "night_restriction", startFreshWorkSession: false)
            return false
        }

        if temporaryDisablePolicy.isActive(state, now: Date()) {
            logManager.logEvent(.appLaunched, context: ["debug": "restore_temporary_disable"])
            workSessionStartTime = nil
            breakSessionStartTime = nil
            postponeStartTime = nil
            postponeDuration = 0
            startTemporaryDisableTimer()
            return true
        }

        expireTemporaryDisable(state, startFreshWorkSession: false)
        return false
    }

    @discardableResult
    private func applyNightRestrictionState(reason: String) -> Bool {
        clearExpiredNightOverride()
        let status = currentNightStatus()

        if temporaryDisableState != nil,
           temporaryDisablePolicy.shouldInterruptActiveDisable(for: status) {
            finishTemporaryDisable(reason: "night_restriction", startFreshWorkSession: false)
        }

        switch status.phase {
        case .locked(let unlockTime):
            enterNightLock(unlockTime: unlockTime, schedule: status.schedule, reason: reason)
            return true

        case .windDown(let limitSeconds, _, _, _, _):
            if isTemporaryDisableActive {
                return true
            }

            if !nightLockOverlays.isEmpty {
                leaveNightLock(startFreshWorkSession: true)
                return true
            }

            if let workSessionStartTime,
               !isPostponeActive,
               !isCompletingWorkSession,
               Date().timeIntervalSince(workSessionStartTime) >= TimeInterval(limitSeconds) {
                print("🌙 夜间收紧阶段达到当前上限，进入休息")
                completeWorkSession()
                return true
            }

            return false

        case .normal:
            if isTemporaryDisableActive {
                return true
            }

            if !nightLockOverlays.isEmpty {
                leaveNightLock(startFreshWorkSession: true)
                return true
            }
            return false
        }
    }

    private func enterNightLock(unlockTime: Date, schedule: NightRestrictionSchedule, reason: String) {
        if !nightLockOverlays.isEmpty {
            refreshNightLockOverlays()
            startNightLockTimer()
            updateMenuTimer()
            updateStatusBarTitle()
            return
        }

        print("🌙 进入夜间禁用：\(reason)")
        cancelInputDeferral()
        dismissPreBreakHUD()
        closeHealthStatsWindowIfNeeded()
        cleanupBreakOverlays()
        smartPauseSnapshot = nil

        countdownScheduler.cancel()

        if let startTime = workSessionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            logManager.logWorkPaused(duration: elapsed, reason: "night_lock_\(reason)")
            eventRecorder.endWorkSession()
        }

        if let startTime = breakSessionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            logManager.logBreakCompleted(actualDuration: elapsed, expectedDuration: currentBreakDuration)
            eventRecorder.endBreakSession()
        }

        workSessionStartTime = nil
        breakSessionStartTime = nil
        postponeStartTime = nil
        postponeDuration = 0
        totalPostponedTime = 0
        activeManualBreak = nil
        activeBreakDurationOverrideSeconds = nil
        saveCurrentSessionState()

        for screen in NSScreen.screens {
            let overlay = NightRestrictionOverlayWindow(screen: screen)
            overlay.nightDelegate = self
            overlay.configureLocked(
                title: AppIdentity.displayName,
                subtitle: localized("nightLockedStatus"),
                unlockTime: unlockTime,
                recoveryFormat: localized("nightOverrideRecoveryFormat"),
                scheduleText: nightScheduleText(schedule),
                overrideButtonTitle: localized("nightOverride")
            )
            overlay.showOverlay()
            nightLockOverlays.append(overlay)
        }

        startNightLockTimer()
        updateMenuTimer()
        updateStatusBarTitle()
    }

    private func startNightLockTimer() {
        rescheduleCountdown()
    }

    private func updateNightLockTimer() {
        if !currentNightStatus().isLocked {
            leaveNightLock(startFreshWorkSession: true)
        }
    }

    private func leaveNightLock(startFreshWorkSession: Bool) {
        countdownScheduler.cancel()

        for overlay in nightLockOverlays {
            overlay.hideOverlay()
        }
        nightLockOverlays.removeAll()

        updateMenuTimer()
        updateStatusBarTitle()

        if startFreshWorkSession, workSessionStartTime == nil, breakSessionStartTime == nil {
            startWorkTimer()
        }
        rescheduleCountdown()
    }

    private func refreshNightLockOverlays() {
        let status = currentNightStatus()
        guard case .locked(let unlockTime) = status.phase else { return }

        let scheduleText = nightScheduleText(status.schedule)
        for overlay in nightLockOverlays {
            overlay.configureLocked(
                title: AppIdentity.displayName,
                subtitle: localized("nightLockedStatus"),
                unlockTime: unlockTime,
                recoveryFormat: localized("nightOverrideRecoveryFormat"),
                scheduleText: scheduleText,
                overrideButtonTitle: localized("nightOverride")
            )
        }
    }

    private func nightScheduleText(_ schedule: NightRestrictionSchedule) -> String {
        "\(schedule.windDownStartTime.displayString) \(localized("nightWindDownStart")) - \(schedule.lockStartTime.displayString) \(localized("nightDisabled"))"
    }

    private func nightWindDownHint(for status: NightRestrictionStatus) -> String? {
        guard case .windDown(let limitSeconds, _, _, let lockStart, _) = status.phase else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let limitText = formatDurationForMenu(limitSeconds)
        return String(format: localized("nightWindDownBreakHint"), limitText, formatter.string(from: lockStart))
    }

    private func nightOverrideOverlayText(for request: NightOverrideRequest) -> NightOverrideOverlayText {
        NightOverrideOverlayText(
            requestTitle: localized("nightOverrideRequestTitle"),
            reasonTitle: localized("nightOverrideReasonTitle"),
            reasonTitles: [
                (.urgentWork, localized("nightOverrideReasonUrgentWork")),
                (.lifeTask, localized("nightOverrideReasonLifeTask")),
                (.family, localized("nightOverrideReasonFamily")),
                (.other, localized("nightOverrideReasonOther"))
            ],
            waitFormat: localized("nightOverrideWaiting"),
            waitExplanation: localized("nightOverrideWaitExplanation"),
            confirmPrompt: localized("nightOverrideConfirmPrompt"),
            confirmationText: localized(request.confirmationLocalizationKey),
            inputPlaceholder: localized("nightOverrideInputPlaceholder"),
            cancelTitle: localized("nightOverrideCancel"),
            unlockTitle: localized("nightOverrideUnlock"),
            mismatchText: localized("nightOverrideMismatch")
        )
    }
    
    // MARK: - Helper Methods
    
    private func updateMenuTimer(now: Date = Date(), status: NightRestrictionStatus? = nil) {
        guard menuIsOpen else { return }
        let nightStatus = status ?? currentNightStatus(now: now)

        if nightStatus.isOverrideActive, let state = nightOverrideState {
            timerMenuItem.title = "\(localized("nightOverrideActiveStatus")) · \(formatStatusBarTime(Int(max(0, state.until.timeIntervalSince(Date())))))"
        } else if nightStatus.isLocked {
            timerMenuItem.title = "\(localized("nightLockedStatus")) · \(localized("nightUnlockTime")) \(nightStatus.schedule.unlockClockTime.displayString)"
        } else if isTemporaryDisableActive {
            timerMenuItem.title = "\(localized("temporaryDisableActiveStatus")) · \(formatStatusBarTime(temporaryDisableRemainingSeconds))"
        } else if isSmartPaused {
            timerMenuItem.title = smartPauseMenuStatusText()
        } else if isWaitingForInputDeferral {
            timerMenuItem.title = inputDeferralMenuStatusText()
        } else if manualBreakSettings.isManualOnlyMode {
            timerMenuItem.title = localized("manualBreakMenuIdleStatus")
        } else if isPostponeActive {
            // 推迟期间显示推迟倒计时
            let totalSeconds = Int(postponeTimeRemaining)
            let minutes = totalSeconds / 60
            let secs = totalSeconds % 60
            timerMenuItem.title = String(format: "%@: %02d:%02d", localized("postponeBreakCountdown"), minutes, secs)
        } else if case .windDown(_, _, _, let lockStart, _) = nightStatus.phase {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            timerMenuItem.title = "\(localized("nightWindDownStatus")): \(formatStatusBarTime(Int(workTimeRemaining))) · \(formatter.string(from: lockStart)) \(localized("nightLockStart"))"
        } else {
            timerMenuItem.title = formatWorkTime(remainingWorkTime(at: now, status: nightStatus))
        }
    }
    
    private func saveCurrentSessionState() {
        logManager.saveSessionState(
            workStartTime: workSessionStartTime,
            breakStartTime: breakSessionStartTime,
            postponeStartTime: postponeStartTime,
            postponeDuration: postponeDuration,
            totalPostponedTime: totalPostponedTime,
            currentWorkDuration: currentWorkDuration,
            currentBreakDuration: currentBreakDuration,
            isCustomMode: isCustomMode,
            pausedBySystemEvent: isPausedBySystemEvent
        )
    }

    private func logSessionDebug(_ action: String, context: [String: String] = [:]) {
        logManager.logSessionDebug(action: action, context: context)
    }

    private func debugTimestamp(_ date: Date?) -> String {
        date.map { String(format: "%.3f", $0.timeIntervalSince1970) } ?? "nil"
    }

    private func updateTemporaryDisableMenuItem() {
        guard temporaryDisableMenuItem != nil else { return }

        let status = currentNightStatus()
        if isTemporaryDisableActive {
            temporaryDisableMenuItem.title = "\(localized("temporaryDisableEndNow")) · \(formatStatusBarTime(temporaryDisableRemainingSeconds))"
            temporaryDisableMenuItem.isEnabled = true
            return
        }

        temporaryDisableMenuItem.title = temporaryDisablePolicy.canStart(in: status)
            ? localized("temporaryDisableOneHour")
            : localized("temporaryDisableUnavailableNight")
        temporaryDisableMenuItem.isEnabled = temporaryDisablePolicy.canStart(in: status)
    }

    private func beginTemporaryDisable(reason: String) {
        let status = currentNightStatus()
        guard temporaryDisablePolicy.canStart(in: status) else {
            updateTemporaryDisableMenuItem()
            _ = applyNightRestrictionState(reason: "temporary_disable_denied")
            return
        }

        let state = temporaryDisablePolicy.grant(now: Date())
        temporaryDisableState = state
        saveTemporaryDisableState()
        eventRecorder.recordTemporaryDisableStarted(state: state, reason: reason)

        countdownScheduler.cancel()
        cancelInputDeferral()
        dismissPreBreakHUD()
        smartPauseSnapshot = nil

        if !breakOverlays.isEmpty {
            cleanupBreakOverlays()
        }

        workSessionStartTime = nil
        breakSessionStartTime = nil
        postponeStartTime = nil
        postponeDuration = 0
        totalPostponedTime = 0
        saveCurrentSessionState()

        startTemporaryDisableTimer()
        updateTemporaryDisableMenuItem()
        updateStatusBarTitle()
        updateMenuTimer()
    }

    private func startTemporaryDisableTimer() {
        updateTemporaryDisableMenuItem()
        rescheduleCountdown()
    }

    private func updateTemporaryDisableTimer() {
        guard let state = temporaryDisableState else {
            countdownScheduler.cancel()
            return
        }

        let status = currentNightStatus()
        if temporaryDisablePolicy.shouldInterruptActiveDisable(for: status) {
            finishTemporaryDisable(reason: "night_restriction", startFreshWorkSession: false)
            _ = applyNightRestrictionState(reason: "temporary_disable_interrupted")
            return
        }

        guard temporaryDisablePolicy.isActive(state, now: Date()) else {
            expireTemporaryDisable(state, startFreshWorkSession: true)
            return
        }

    }

    private func finishTemporaryDisable(reason: String, startFreshWorkSession: Bool) {
        guard let state = temporaryDisableState else { return }

        countdownScheduler.cancel()
        temporaryDisableState = nil
        saveTemporaryDisableState()
        eventRecorder.recordTemporaryDisableEnded(state: state, reason: reason)
        updateTemporaryDisableMenuItem()
        updateStatusBarTitle()
        updateMenuTimer()

        if startFreshWorkSession {
            startWorkTimer()
        }
        rescheduleCountdown()
    }

    private func expireTemporaryDisable(_ state: TemporaryDisableState, startFreshWorkSession: Bool) {
        countdownScheduler.cancel()
        temporaryDisableState = nil
        saveTemporaryDisableState()
        eventRecorder.recordTemporaryDisableExpired(state: state)
        updateTemporaryDisableMenuItem()
        updateStatusBarTitle()
        updateMenuTimer()

        if startFreshWorkSession {
            startWorkTimer()
        }
        rescheduleCountdown()
    }
    
    private func startStateSnapshotTimer() {
        stateSnapshotTimer?.invalidate()
        let timer = Timer(timeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.recordStateSnapshot()
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
        stateSnapshotTimer = timer
    }
    
    private func stopStateSnapshotTimer() {
        stateSnapshotTimer?.invalidate()
        stateSnapshotTimer = nil
    }
    
    private func recordStateSnapshot() {
        let currentMode = isTemporaryDisableActive ? "temporary_disable" : (isCustomMode ? "custom" : "default")
        
        logManager.logStateSnapshot(
            workStartTime: workSessionStartTime,
            breakStartTime: breakSessionStartTime,
            workRemaining: workTimeRemaining,
            breakRemaining: breakTimeRemaining,
            currentMode: currentMode
        )
        
        // 同时保存会话状态
        saveCurrentSessionState()
        traceCountdownTiming(event: "snapshot")
    }
    
    private func showBreakOverlay(bypassInputDeferral: Bool = false) {
        print("🎭 showBreakOverlay 被调用")
        dismissPreBreakHUD()

        if applyNightRestrictionState(reason: "before_break_overlay") {
            cancelInputDeferral()
            rescheduleCountdown()
            return
        }

        if isSmartPaused {
            cancelInputDeferral()
            if smartPauseSnapshot == nil {
                smartPauseSnapshot = SmartPauseSnapshot(
                    remainingWorkTime: nil,
                    remainingPostponeTime: nil,
                    hadDeferredBreak: true
                )
            } else {
                smartPauseSnapshot?.hadDeferredBreak = true
            }
            workSessionStartTime = nil
            postponeStartTime = nil
            postponeDuration = 0
            updateStatusBarTitle()
            updateMenuTimer()
            rescheduleCountdown()
            return
        }

        if !bypassInputDeferral, activePlannedBreakOccurrence == nil, activeCalendarBreakOccurrence == nil, shouldDeferBreakForInputActivity() {
            return
        }

        if activePlannedBreakOccurrence == nil && activeCalendarBreakOccurrence == nil {
            let now = Date()
            let evaluation = plannedBreakPolicy.evaluate(
                settings: plannedBreakSettings,
                state: plannedBreakState,
                now: now,
                smartPauseEvaluation: smartPauseEvaluation,
                isNightLocked: currentNightStatus(now: now).isLocked,
                isTemporarilyDisabled: isTemporaryDisableActive
            )
            plannedBreakState = evaluation.nextState
            switch evaluation.decision {
            case .trigger(let occurrence, let remainingSeconds):
                activePlannedBreakOccurrence = occurrence
                plannedBreakState.activeOccurrence = occurrence
                activeBreakDurationOverrideSeconds = remainingSeconds
            case .deferredBySmartPause, .creditedAway, .expired, .none:
                if evaluation.shouldSuppressRegularBreak {
                    cancelInputDeferral()
                    workSessionStartTime = nil
                    postponeStartTime = nil
                    postponeDuration = 0
                    logSessionDebug("regular_break_suppressed_by_planned_break", context: [
                        "planned_break": evaluation.suppressedByOccurrence?.schedule.name ?? "unknown"
                    ])
                    updateStatusBarTitle(now: now)
                    updateMenuTimer(now: now)
                    rescheduleCountdown()
                    return
                }
            }

            if activePlannedBreakOccurrence == nil {
                let calendarEvaluation = calendarBreakPolicy.evaluate(
                    settings: calendarBreakSettings,
                    snapshot: calendarEventMonitor.lastSnapshot,
                    state: calendarBreakState,
                    now: now,
                    smartPauseEvaluation: smartPauseEvaluation,
                    isNightLocked: currentNightStatus(now: now).isLocked,
                    isTemporarilyDisabled: isTemporaryDisableActive
                )
                calendarBreakState = calendarEvaluation.nextState
                switch calendarEvaluation.decision {
                case .trigger(let occurrence, let remainingSeconds),
                     .resumePostponed(let occurrence, let remainingSeconds):
                    activeCalendarBreakOccurrence = occurrence
                    calendarBreakState.activeOccurrence = occurrence
                    activeBreakDurationOverrideSeconds = remainingSeconds
                case .deferredBySmartPause, .creditedAway, .expired, .activeEventRemoved, .none:
                    if calendarEvaluation.shouldSuppressRegularBreak {
                        cancelInputDeferral()
                        workSessionStartTime = nil
                        postponeStartTime = nil
                        postponeDuration = 0
                        logSessionDebug("regular_break_suppressed_by_calendar_break", context: [
                            "calendar_break": calendarEvaluation.suppressedByOccurrence?.title ?? "unknown"
                        ])
                        updateStatusBarTitle(now: now)
                        updateMenuTimer(now: now)
                        rescheduleCountdown()
                        return
                    }
                }
            }
        }

        cancelInputDeferral()

        closeHealthStatsWindowIfNeeded()

        // 防止重复创建窗口 - 如果已有窗口，先清理
        if !breakOverlays.isEmpty {
            print("⚠️ 检测到已存在 \(breakOverlays.count) 个休息窗口，先清理")
            cleanupBreakOverlays()
        }

        // 检查屏幕是否可用
        guard !NSScreen.screens.isEmpty else {
            print("❌ 没有可用屏幕")
            logManager.logEvent(.breakSkipped, context: ["reason": "no_screens_available"])
            if let active = activePlannedBreakOccurrence {
                plannedBreakState.markHandled(active, status: .expired)
                activePlannedBreakOccurrence = nil
                activeBreakDurationOverrideSeconds = nil
            }
            if let activeCalendar = activeCalendarBreakOccurrence {
                calendarBreakState.markHandled(activeCalendar, status: .expired)
                activeCalendarBreakOccurrence = nil
                activeBreakDurationOverrideSeconds = nil
            }
            // 屏幕不可用，延迟1秒后重新开始工作会话
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.startWorkTimer()
            }
            return
        }

        print("📺 检测到 \(NSScreen.screens.count) 个屏幕")

        // 结束工作会话，开始休息会话
        workSessionStartTime = nil
        breakSessionStartTime = Date()
        saveCurrentSessionState()

        // 使用新的事件记录器
        eventRecorder.startBreakSession(duration: effectiveBreakDuration)

        // 为每个屏幕创建一个覆盖窗口
        print("🔄 清空旧的 breakOverlays（当前有 \(breakOverlays.count) 个）")
        breakOverlays.removeAll()
        
        for (index, screen) in NSScreen.screens.enumerated() {
            let screenInfo = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"
            print("  📺 为屏幕 \(index + 1)/\(NSScreen.screens.count) 创建窗口 - 屏幕ID: \(screenInfo)")
            
            let overlay = BreakOverlayWindow(screen: screen)
            overlay.breakDelegate = self
            overlay.setLocalizer(localized)
            if let manual = activeManualBreak {
                let manualTitle = manual.title.isEmpty ? localized("manualBreakDefaultTitle") : manual.title
                overlay.configureNamedBreak(title: manualTitle, formatKey: "manualBreakOverlayFormat")
            } else if let planned = activePlannedBreakOccurrence {
                overlay.configureNamedBreak(title: planned.schedule.name, formatKey: "plannedBreakOverlayFormat")
            } else if let calendarOccurrence = activeCalendarBreakOccurrence {
                let calendarTitle = calendarOccurrence.title.isEmpty
                    ? localized("calendarBreakDefaultTitle")
                    : calendarOccurrence.title
                overlay.configureNamedBreak(title: calendarTitle, formatKey: "plannedBreakOverlayFormat")
            } else {
                overlay.configureNamedBreak(title: nil)
            }
            overlay.updateCountdown(Int(breakTimeRemaining))

            // 更新推迟状态显示
            let usedMinutes = Int(totalPostponedTime / 60)
            let remainingMinutes = Int((maxTotalPostponeTime - totalPostponedTime) / 60)
            overlay.updatePostponeStatus(used: usedMinutes, remaining: remainingMinutes)
            overlay.setNightWindDownHint(nightWindDownHint(for: currentNightStatus()))
            overlay.updateSkipState(
                breakSkipPolicy.state(
                    settings: breakSkipSettings,
                    breakStartTime: breakSessionStartTime,
                    now: Date()
                )
            )

            overlay.showOverlay()
            breakOverlays.append(overlay)
            
            print("     - 窗口创建成功: \(overlay)")
        }
        
        print("✅ 创建了 \(breakOverlays.count) 个休息窗口")
        
        // 如果没有成功创建任何覆盖窗口，回退到工作状态
        if breakOverlays.isEmpty {
            print("❌ 没有成功创建任何窗口")
            logManager.logEvent(.breakSkipped, context: ["reason": "overlay_creation_failed"])
            startWorkTimer()
            return
        }
        
        startBreakTimer()
    }
    
    private func startBreakTimer() {
        rescheduleCountdown()
    }
    
    private func updateBreakTimer() {
        if applyNightRestrictionState(reason: "break_timer_tick") {
            return
        }

        // 检测异常情况：如果休息时间已经超过预期很多，可能是系统睡眠导致的
        if let breakStart = breakSessionStartTime {
            let elapsed = Date().timeIntervalSince(breakStart)
            if elapsed > TimeInterval(effectiveBreakDuration + 60) { // 超过预期时间1分钟以上
                print("⚠️ 检测到异常的休息时长: \(elapsed)秒, 预期: \(effectiveBreakDuration)秒")
                print("   可能是系统睡眠导致的，立即完成休息会话")
                completeBreakSession()
                return
            }
        }

        // 正常完成休息
        if breakTimeRemaining <= 0 && !isCompletingBreakSession {
            completeBreakSession()
        }
    }
    
    private func completeBreakSession() {
        // 设置标志防止重入
        isCompletingBreakSession = true
        
        // 首先停止定时器，无论后续操作是否成功
        countdownScheduler.cancel()
        
        cleanupBreakOverlays()
        
        if let startTime = breakSessionStartTime {
            let actualDuration = Date().timeIntervalSince(startTime)
            logManager.logBreakCompleted(actualDuration: actualDuration, expectedDuration: effectiveBreakDuration)
        }

        if let active = activePlannedBreakOccurrence {
            plannedBreakState.markHandled(active, status: .completed)
            activePlannedBreakOccurrence = nil
            activeBreakDurationOverrideSeconds = nil
        }
        if let activeCalendar = activeCalendarBreakOccurrence {
            calendarBreakState.markHandled(activeCalendar, status: .completed)
            activeCalendarBreakOccurrence = nil
            activeBreakDurationOverrideSeconds = nil
        }

        // 记录休息完成到数据库
        eventRecorder.endBreakSession()

        if let manual = activeManualBreak {
            activeManualBreak = nil
            activeBreakDurationOverrideSeconds = nil
            let action = manualBreakPolicy.finishManualBreak(
                manual,
                outcome: .completed,
                settings: manualBreakSettings,
                fullWorkDuration: TimeInterval(effectiveWorkDuration),
                now: Date()
            )
            applyManualBreakPostAction(action)
            isCompletingBreakSession = false
            return
        }

        startWorkTimer(forceFreshSession: true)
        
        // 清除标志
        isCompletingBreakSession = false
    }

    private func skipBreakSession() {
        guard !isCompletingBreakSession else { return }
        guard let breakStart = breakSessionStartTime else { return }
        let now = Date()
        guard breakSkipPolicy.isSkipUnlocked(
            settings: breakSkipSettings,
            breakStartTime: breakStart,
            now: now
        ) else {
            return
        }

        isCompletingBreakSession = true
        countdownScheduler.cancel()
        cleanupBreakOverlays()

        let actualDuration = max(0, now.timeIntervalSince(breakStart))
        let expected = effectiveBreakDuration
        if let active = activePlannedBreakOccurrence {
            plannedBreakState.markHandled(active, status: .completed)
            activePlannedBreakOccurrence = nil
            activeBreakDurationOverrideSeconds = nil
        }
        if let activeCalendar = activeCalendarBreakOccurrence {
            calendarBreakState.markHandled(activeCalendar, status: .skipped)
            activeCalendarBreakOccurrence = nil
            activeBreakDurationOverrideSeconds = nil
        }
        eventRecorder.skipBreakSession(
            actualDuration: actualDuration,
            expectedDuration: expected
        )

        if let manual = activeManualBreak {
            activeManualBreak = nil
            activeBreakDurationOverrideSeconds = nil
            let action = manualBreakPolicy.finishManualBreak(
                manual,
                outcome: .skipped,
                settings: manualBreakSettings,
                fullWorkDuration: TimeInterval(effectiveWorkDuration),
                now: now
            )
            applyManualBreakPostAction(action)
            isCompletingBreakSession = false
            return
        }

        startWorkTimer(forceFreshSession: true)
        isCompletingBreakSession = false
    }
    
    private func cleanupBreakOverlays() {
        // 彻底清理所有休息窗口
        print("🧹 开始清理休息窗口 - 共 \(breakOverlays.count) 个")
        
        for (index, overlay) in breakOverlays.enumerated() {
            let screenInfo = overlay.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? "unknown"
            print("  📺 清理窗口 \(index + 1)/\(breakOverlays.count) - 屏幕: \(screenInfo)")
            print("     - 窗口状态: isVisible=\(overlay.isVisible), level=\(overlay.level.rawValue)")
            print("     - 窗口对象: \(overlay)")
            
            overlay.hideOverlay()
            
            print("     - 清理后: isVisible=\(overlay.isVisible)")
        }
        
        let countBefore = breakOverlays.count
        breakOverlays.removeAll()
        print("✅ 窗口清理完成 - 清理前: \(countBefore) 个, 清理后: \(breakOverlays.count) 个")
    }

    private func closeHealthStatsWindowIfNeeded() {
        guard let window = healthStatsWindow else { return }

        window.close()
        healthStatsWindow = nil
        print("📊 进入休息时关闭统计窗口，避免休息结束后自动露出")
    }
    
    private func postponeBreak(minutes: Int) {
        print("🚀 postponeBreak 被调用 - 推迟 \(minutes) 分钟")
        print("  - 当前 breakOverlays 数量: \(breakOverlays.count)")
        print("  - 当前屏幕数量: \(NSScreen.screens.count)")

        let postponeSeconds = TimeInterval(minutes * 60)

        // 检查是否超过累计上限（10分钟）
        if totalPostponedTime + postponeSeconds > maxTotalPostponeTime {
            print("⚠️ 已达推迟上限，累计推迟: \(Int(totalPostponedTime / 60)) 分钟，无法继续推迟 \(minutes) 分钟")
            return
        }

        // 累加推迟时间
        totalPostponedTime += postponeSeconds
        print("📊 累计推迟: \(Int(totalPostponedTime / 60)) 分钟，剩余可推迟: \(Int((maxTotalPostponeTime - totalPostponedTime) / 60)) 分钟")
        
        // 记录推迟的休息
        // 使用新的事件记录器
        eventRecorder.recordPostpone(minutes: minutes)
        
        print("⏸️ 停止休息计时器")
        countdownScheduler.cancel()
        
        print("🧹 调用 cleanupBreakOverlays")
        cleanupBreakOverlays()

        breakSessionStartTime = nil

        let now = Date()
        let postponeInterval = TimeInterval(minutes * 60)
        if let activeCalendar = activeCalendarBreakOccurrence {
            calendarBreakState.postpone(activeCalendar, until: now.addingTimeInterval(postponeInterval))
            activeCalendarBreakOccurrence = nil
            activeBreakDurationOverrideSeconds = nil
        }
        if activeManualBreak != nil {
            activeManualBreak = nil
            activeBreakDurationOverrideSeconds = nil
        }

        // 更新所有休息窗口的推迟状态显示（如果有的话）
        updateBreakOverlaysPostponeStatus()
        
        // 开始推迟计时器 - 不修改原始工作时长设置
        postponeStartTime = now
        postponeDuration = postponeInterval
        
        // 保持原始工作时长不变，不保存临时状态到会话文件
        logManager.logWorkStarted(mode: "postponed_\(minutes)min")

        updateStatusBarTitle()
        updateMenuTimer()
        saveCurrentSessionState()
        startPostponeTimer()
    }

    private func startPostponeTimer() {
        rescheduleCountdown()
    }

    private func updatePostponeTimer() {
        if applyNightRestrictionState(reason: "postpone_deadline") { return }
        if postponeTimeRemaining <= 0 {
            countdownScheduler.cancel()
            postponeStartTime = nil
            postponeDuration = 0
            saveCurrentSessionState()
            showBreakOverlay()
        }
    }
    
    // MARK: - System Event Handlers
    
    @objc private func systemWillSleep() {
        print("🛌 System will sleep - pausing session")
        pauseCurrentSession(reason: "system_sleep")
        logManager.logEvent(.systemSleep)
    }
    
    @objc private func systemDidWake() {
        print("🌅 System did wake - evaluating session")
        logManager.logEvent(.systemWake)
        evaluateAndResumeSession(reason: "system_wake")
    }
    
    @objc private func screenDidLock() {
        print("🔒 Screen did lock - pausing session")
        pauseCurrentSession(reason: "screen_lock")
        logManager.logEvent(.screenLock)
    }
    
    @objc private func screenDidUnlock() {
        print("🔓 Screen did unlock - evaluating session")
        logManager.logEvent(.screenUnlock)
        evaluateAndResumeSession(reason: "screen_unlock")
    }
    
    @objc private func screensDidSleep() {
        print("📺 Screens did sleep - pausing session")
        pauseCurrentSession(reason: "display_sleep")
        logManager.logEvent(.displaySleep)
    }
    
    @objc private func screensDidWake() {
        print("📺 Screens did wake - evaluating session")
        logManager.logEvent(.displayWake)
        evaluateAndResumeSession(reason: "display_wake")
    }
    
    @objc private func screensaverDidStart() {
        print("🖥️ Screensaver did start - pausing session")
        pauseCurrentSession(reason: "screensaver_start")
        logManager.logEvent(.screensaverStart)
    }
    
    @objc private func screensaverDidStop() {
        print("🖥️ Screensaver did stop - evaluating session")
        logManager.logEvent(.screensaverStop)
        evaluateAndResumeSession(reason: "screensaver_stop")
    }
    
    private func pauseCurrentSession(reason: String) {
        displaysAreActive = false
        awayStartedAtForPlannedBreak = awayStartedAtForPlannedBreak ?? Date()
        if activePlannedBreakOccurrence != nil {
            activePlannedBreakOccurrence = nil
            activeBreakDurationOverrideSeconds = nil
            plannedBreakState.activeOccurrence = nil
        }
        if activeCalendarBreakOccurrence != nil {
            activeCalendarBreakOccurrence = nil
            activeBreakDurationOverrideSeconds = nil
            calendarBreakState.activeOccurrence = nil
        }
        if activeManualBreak != nil {
            activeManualBreak = nil
            activeBreakDurationOverrideSeconds = nil
        }
        smartPauseSnapshot = nil
        cancelInputDeferral()
        inputActivityProvider.resetTracking()
        countdownScheduler.cancel()
        dismissPreBreakHUD()
        logSessionDebug("system_pause_current_session", context: [
            "reason": reason,
            "work_start_time": debugTimestamp(workSessionStartTime),
            "break_start_time": debugTimestamp(breakSessionStartTime),
            "postpone_start_time": debugTimestamp(postponeStartTime),
            "postpone_duration": "\(Int(postponeDuration))",
            "total_postponed_time": "\(Int(totalPostponedTime))",
            "overlay_count": "\(breakOverlays.count)"
        ])

        if let startTime = workSessionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            logManager.logWorkPaused(duration: elapsed, reason: "system_pause_\(reason)")
            eventRecorder.endActiveSessionForSystemPause(reason: reason)
        } else if breakSessionStartTime != nil {
            eventRecorder.endBreakSession()
        } else if postponeStartTime != nil {
            eventRecorder.endActiveSessionForSystemPause(reason: reason)
        }

        let pausedState = SessionState(
            workStartTime: workSessionStartTime,
            breakStartTime: breakSessionStartTime,
            postponeStartTime: postponeStartTime,
            postponeDuration: postponeDuration,
            totalPostponedTime: totalPostponedTime,
            currentWorkDuration: currentWorkDuration,
            currentBreakDuration: currentBreakDuration,
            isCustomMode: isCustomMode,
            lastSaved: Date(),
            pausedBySystemEvent: false
        ).pausedForSystemEvent(now: Date())

        workSessionStartTime = pausedState.workStartTime
        breakSessionStartTime = pausedState.breakStartTime
        postponeStartTime = pausedState.postponeStartTime
        postponeDuration = pausedState.postponeDuration
        totalPostponedTime = pausedState.totalPostponedTime
        isPausedBySystemEvent = pausedState.pausedBySystemEvent
        saveCurrentSessionState()
        rescheduleCountdown()
    }
    
    private func evaluateAndResumeSession(reason: String) {
        displaysAreActive = true
        let resumeNow = Date()
        let awayInterval = awayStartedAtForPlannedBreak.map { DateInterval(start: min($0, resumeNow), end: resumeNow) }
        awayStartedAtForPlannedBreak = nil
        countdownScheduler.cancel()
        // 首先检查并清理任何残留的休息窗口
        logSessionDebug("system_resume_evaluate", context: [
            "reason": reason,
            "work_start_time": debugTimestamp(workSessionStartTime),
            "break_start_time": debugTimestamp(breakSessionStartTime),
            "postpone_start_time": debugTimestamp(postponeStartTime),
            "postpone_duration": "\(Int(postponeDuration))",
            "overlay_count": "\(breakOverlays.count)"
        ])

        if !breakOverlays.isEmpty {
            print("⚠️ 检测到系统唤醒后有 \(breakOverlays.count) 个残留休息窗口，先清理")
            cleanupBreakOverlays()
        }

        // 用户需求：无论之前什么状态，打开电脑后应该直接进入「工作状态」
        // 方案：任何系统唤醒事件都重置为新的工作会话
        print("🔄 系统唤醒 (\(reason)) - 重置为新的工作会话")

        // 记录之前的会话状态
        if let workStart = workSessionStartTime {
            let elapsed = Date().timeIntervalSince(workStart)
            logManager.logWorkPaused(duration: elapsed, reason: "system_wake_reset_\(reason)")
        } else if let breakStart = breakSessionStartTime {
            let elapsed = Date().timeIntervalSince(breakStart)
            logManager.logBreakCompleted(actualDuration: elapsed, expectedDuration: currentBreakDuration)
            // 记录休息完成到数据库
            eventRecorder.endBreakSession()
        }

        // 清理定时器
        countdownScheduler.cancel()

        // 重置为新的工作会话
        workSessionStartTime = nil
        breakSessionStartTime = nil
        logSessionDebug("system_resume_start_fresh_work", context: [
            "reason": reason
        ])
        if evaluatePlannedBreaks(now: resumeNow, awayInterval: awayInterval) {
            return
        }
        if evaluateCalendarBreaks(now: resumeNow, awayInterval: awayInterval) {
            return
        }
        restartWorkTimer()
    }
}

extension AppDelegate: BreakOverlayDelegate {
    func didRequestPostpone(minutes: Int) {
        postponeBreak(minutes: minutes)
    }

    func didRequestSkipBreak() {
        skipBreakSession()
    }
}

extension AppDelegate: NightRestrictionOverlayDelegate {
    func didRequestNightOverride() {
        let status = currentNightStatus()
        guard case .locked = status.phase else {
            leaveNightLock(startFreshWorkSession: true)
            return
        }

        let nightKey = nightOverridePolicy.nightKey(for: status.schedule)
        let request = nightOverridePolicy.request(overrideNumberForNight: nightOverrideCount(for: nightKey) + 1)
        eventRecorder.recordNightOverrideRequested(nightKey: nightKey, request: request)

        let text = nightOverrideOverlayText(for: request)
        for overlay in nightLockOverlays {
            overlay.configureOverrideRequest(request, text: text)
        }
    }

    func didCancelNightOverride(request: NightOverrideRequest) {
        let status = currentNightStatus()
        let nightKey = nightOverridePolicy.nightKey(for: status.schedule)
        eventRecorder.recordNightOverrideCancelled(nightKey: nightKey, request: request)
        refreshNightLockOverlays()
    }

    func didGrantNightOverride(reason: NightOverrideReason, request: NightOverrideRequest) {
        let status = currentNightStatus()
        guard case .locked = status.phase else {
            leaveNightLock(startFreshWorkSession: true)
            return
        }

        let nightKey = nightOverridePolicy.nightKey(for: status.schedule)
        let state = nightOverridePolicy.grant(
            now: Date(),
            reason: reason,
            nightKey: nightKey,
            overrideNumberForNight: request.overrideNumberForNight
        )
        nightOverrideState = state
        saveNightOverrideState()
        saveNightOverrideCount(request.overrideNumberForNight, nightKey: nightKey)
        eventRecorder.recordNightOverrideGranted(state: state, request: request)
        leaveNightLock(startFreshWorkSession: true)
        rebuildNightRestrictionMenu()
        updateMenuTimer()
        updateStatusBarTitle()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // 如果关闭的是统计窗口，清理引用
        if let window = notification.object as? StatsDashboardWindow, window == healthStatsWindow {
            healthStatsWindow = nil
            print("📊 统计窗口引用已清理")
        }
    }
}

// MARK: - Helper Methods

extension AppDelegate {
    /// 更新所有休息窗口的推迟状态显示
    private func updateBreakOverlaysPostponeStatus() {
        let usedMinutes = Int(totalPostponedTime / 60)
        let remainingMinutes = Int((maxTotalPostponeTime - totalPostponedTime) / 60)

        for overlay in breakOverlays {
            overlay.updatePostponeStatus(used: usedMinutes, remaining: remainingMinutes)
        }
    }

    private func updateBreakOverlaysSkipState() {
        let state = breakSkipPolicy.state(
            settings: breakSkipSettings,
            breakStartTime: breakSessionStartTime,
            now: Date()
        )
        for overlay in breakOverlays {
            overlay.updateSkipState(state)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        updateMenuTimer()
        updateLoginItemState()
        updateShowCountdownState()
        updateStrictModeMenuState()
        updateSkipDelayMenuStates()
        updateTemporaryDisableMenuItem()
        updateModeMenuStates()
        rebuildManualBreakMenu()
        rebuildPlannedBreaksMenu()
        rebuildCalendarBreaksMenu()
        rebuildNightRestrictionMenu()
        rebuildSmartPauseMenu()
        startMenuUpdateTimer()
    }
    
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        stopMenuUpdateTimer()
    }
    
    private func startMenuUpdateTimer() {
        refreshCountdownDisplayAndTimer()
    }
    
    private func stopMenuUpdateTimer() {
        refreshCountdownDisplayAndTimer()
    }
    
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let langCode = sender.representedObject as? String else { return }
        
        currentLanguage = langCode
        saveSettings()
        
        // Update language menu items
        for item in languageMenuItems {
            item.state = (item.representedObject as? String == currentLanguage) ? .on : .off
        }
        
        // Refresh the entire menu with new language
        menu.removeAllItems()
        setupMenu()
        
        // Update break overlays if they exist
        for overlay in breakOverlays {
            overlay.setLocalizer(localized)
        }
        preBreakHUDWindow?.setLocalizer(localized)
        refreshNightLockOverlays()
        refreshCountdownDisplayAndTimer()
    }
}

extension AppDelegate: PreBreakHUDDelegate {
    private func preBreakLeadTimeTitle(_ option: PreBreakLeadTime) -> String {
        switch option {
        case .off:
            return localized("preBreakOff")
        case .seconds10:
            return localized("preBreakSeconds10")
        case .seconds20:
            return localized("preBreakSeconds20")
        case .seconds30:
            return localized("preBreakSeconds30")
        }
    }

    @objc private func selectPreBreakLeadTime(_ sender: NSMenuItem) {
        preBreakLeadTime = PreBreakLeadTime.validated(sender.tag)
        saveSettings()
        for item in preBreakLeadTimeMenuItems {
            item.state = (item.tag == preBreakLeadTime.rawValue) ? .on : .off
        }
        rescheduleCountdown()
    }

    private func updatePreBreakHUD(now: Date, status: NightRestrictionStatus) {
        guard displaysAreActive,
              !status.isLocked,
              !isTemporaryDisableActive,
              !isSmartPaused,
              breakSessionStartTime == nil,
              breakOverlays.isEmpty else {
            dismissPreBreakHUD()
            return
        }

        if shouldSuppressRegularBreakForPlannedBreak(now: now) {
            dismissPreBreakHUD()
            return
        }

        let state: PreBreakHeadsUpState
        if let postponeStart = postponeStartTime {
            let remaining = max(0, postponeDuration - now.timeIntervalSince(postponeStart))
            state = preBreakPolicy.state(
                remainingTime: remaining,
                leadTime: preBreakLeadTime,
                workDurationSeconds: Int(postponeDuration),
                isWorkOrPostponeActive: true
            )
        } else if let workStart = workSessionStartTime {
            let workDuration = status.effectiveWorkDurationSeconds
            let remaining = max(0, TimeInterval(workDuration) - now.timeIntervalSince(workStart))
            state = preBreakPolicy.state(
                remainingTime: remaining,
                leadTime: preBreakLeadTime,
                workDurationSeconds: workDuration,
                isWorkOrPostponeActive: true
            )
        } else {
            state = .inactive
        }

        guard case .active(let remainingSeconds) = state else {
            dismissPreBreakHUD()
            return
        }

        let hud: PreBreakHUDWindow
        if let existing = preBreakHUDWindow {
            hud = existing
        } else {
            let created = PreBreakHUDWindow()
            created.hudDelegate = self
            created.setLocalizer(localized)
            preBreakHUDWindow = created
            hud = created
        }

        let canSnooze1 = preBreakPolicy.canSnooze(
            minutes: 1,
            totalPostponedTime: totalPostponedTime,
            maxTotalPostponeTime: maxTotalPostponeTime
        )
        let canSnooze5 = preBreakPolicy.canSnooze(
            minutes: 5,
            totalPostponedTime: totalPostponedTime,
            maxTotalPostponeTime: maxTotalPostponeTime
        )
        hud.showHUD(remainingSeconds: remainingSeconds, canSnooze1Min: canSnooze1, canSnooze5Min: canSnooze5)
    }

    private func dismissPreBreakHUD() {
        preBreakHUDWindow?.dismissHUD()
    }

    func didRequestPreBreakSnooze(minutes: Int) {
        guard preBreakPolicy.snooze(
            minutes: minutes,
            totalPostponedTime: totalPostponedTime,
            maxTotalPostponeTime: maxTotalPostponeTime
        ) != nil else {
            return
        }

        dismissPreBreakHUD()
        cancelInputDeferral()

        let postponeSeconds = TimeInterval(minutes * 60)
        totalPostponedTime += postponeSeconds
        eventRecorder.recordPostpone(minutes: minutes)

        countdownScheduler.cancel()
        if let startTime = workSessionStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            logManager.logWorkPaused(duration: elapsed, reason: "pre_break_snooze_\(minutes)min")
        }

        workSessionStartTime = nil
        breakSessionStartTime = nil
        postponeStartTime = Date()
        postponeDuration = postponeSeconds

        logManager.logWorkStarted(mode: "postponed_\(minutes)min")
        updateStatusBarTitle()
        updateMenuTimer()
        saveCurrentSessionState()
        rescheduleCountdown()
    }

    func didRequestPreBreakSkip() {
        _ = preBreakPolicy.skip()
        dismissPreBreakHUD()
        cancelInputDeferral()
        logManager.logEvent(.breakSkipped, context: ["reason": "pre_break_skip"])
        restartWorkTimer()
    }
}

// MARK: - Smart Pause

extension AppDelegate {
    private func setupSmartPauseMenu() {
        smartPauseMenuItem = NSMenuItem(title: localized("smartPause"), action: nil, keyEquivalent: "")
        smartPauseMenuItem.submenu = buildSmartPauseSubmenu()
        menu.addItem(smartPauseMenuItem)
    }

    private func rebuildSmartPauseMenu() {
        guard smartPauseMenuItem != nil else { return }
        smartPauseMenuItem.title = localized("smartPause")
        smartPauseMenuItem.submenu = buildSmartPauseSubmenu()
    }

    private func buildSmartPauseSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let screenCaptureEnabledItem = NSMenuItem(
            title: localized("smartPauseScreenCaptureEnabled"),
            action: #selector(toggleScreenCapturePause),
            keyEquivalent: ""
        )
        screenCaptureEnabledItem.target = self
        screenCaptureEnabledItem.state = screenCaptureSettings.isEnabled ? .on : .off
        submenu.addItem(screenCaptureEnabledItem)

        if screenCaptureSettings.isEnabled && screenCaptureMonitor.lastSnapshot.permissionState == .denied {
            submenu.addItem(disabledMenuItem(localized("smartPauseScreenCaptureLimitedPermission")))
        }

        let meetingEnabledItem = NSMenuItem(
            title: localized("smartPauseMeetingEnabled"),
            action: #selector(toggleMeetingAutoPause),
            keyEquivalent: ""
        )
        meetingEnabledItem.target = self
        meetingEnabledItem.state = meetingAutoPauseSettings.isEnabled ? .on : .off
        submenu.addItem(meetingEnabledItem)

        let fullscreenEnabledItem = NSMenuItem(
            title: localized("smartPauseFullscreenEnabled"),
            action: #selector(toggleFullscreenPause),
            keyEquivalent: ""
        )
        fullscreenEnabledItem.target = self
        fullscreenEnabledItem.state = focusAppPauseSettings.fullscreenPauseEnabled ? .on : .off
        submenu.addItem(fullscreenEnabledItem)

        let waitForInputItem = NSMenuItem(
            title: localized("smartPauseWaitForInputEnabled"),
            action: #selector(toggleWaitForInput),
            keyEquivalent: ""
        )
        waitForInputItem.target = self
        waitForInputItem.state = inputDeferralSettings.isEnabled ? .on : .off
        submenu.addItem(waitForInputItem)

        let maxWaitItem = NSMenuItem(
            title: localized("smartPauseMaxWait"),
            action: nil,
            keyEquivalent: ""
        )
        maxWaitItem.submenu = buildMaxWaitThresholdSubmenu()
        submenu.addItem(maxWaitItem)

        let idleEnabledItem = NSMenuItem(
            title: localized("smartPauseIdleEnabled"),
            action: #selector(toggleIdlePause),
            keyEquivalent: ""
        )
        idleEnabledItem.target = self
        idleEnabledItem.state = idleNaturalBreakSettings.isEnabled ? .on : .off
        submenu.addItem(idleEnabledItem)

        let idleThresholdItem = NSMenuItem(
            title: localized("smartPauseIdleThreshold"),
            action: nil,
            keyEquivalent: ""
        )
        idleThresholdItem.submenu = buildIdleThresholdSubmenu()
        submenu.addItem(idleThresholdItem)

        submenu.addItem(NSMenuItem.separator())

        let calendarEventsItem = NSMenuItem(
            title: localized("smartPauseCalendarEvents"),
            action: nil,
            keyEquivalent: ""
        )
        calendarEventsItem.submenu = buildCalendarEventsSubmenu()
        submenu.addItem(calendarEventsItem)

        let excludedAppsItem = NSMenuItem(
            title: localized("smartPauseExcludedApps"),
            action: nil,
            keyEquivalent: ""
        )
        excludedAppsItem.submenu = buildExcludedAppsSubmenu()
        submenu.addItem(excludedAppsItem)

        let deepFocusAppsItem = NSMenuItem(
            title: localized("smartPauseDeepFocusApps"),
            action: nil,
            keyEquivalent: ""
        )
        deepFocusAppsItem.submenu = buildDeepFocusAppsSubmenu()
        submenu.addItem(deepFocusAppsItem)

        return submenu
    }

    private func buildCalendarEventsSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let snapshot = calendarEventMonitor.currentSnapshot()

        let enabledItem = NSMenuItem(
            title: localized("smartPauseCalendarEnabled"),
            action: #selector(toggleCalendarPause),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = calendarPauseSettings.isEnabled ? .on : .off
        submenu.addItem(enabledItem)

        switch snapshot.permissionState {
        case .notDetermined:
            let grantItem = NSMenuItem(
                title: localized("smartPauseCalendarGrantAccess"),
                action: #selector(requestCalendarAccess),
                keyEquivalent: ""
            )
            grantItem.target = self
            submenu.addItem(grantItem)
        case .denied, .restricted:
            submenu.addItem(disabledMenuItem(localized("smartPauseCalendarPermissionDenied")))
            let settingsItem = NSMenuItem(
                title: localized("smartPauseCalendarOpenSettings"),
                action: #selector(openCalendarSettings),
                keyEquivalent: ""
            )
            settingsItem.target = self
            submenu.addItem(settingsItem)
        case .authorized:
            break
        }

        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(disabledMenuItem(localized("smartPauseCalendarBreakAction")))

        let postponeItem = NSMenuItem(
            title: localized("smartPauseCalendarActionPostpone"),
            action: #selector(selectCalendarBreakAction(_:)),
            keyEquivalent: ""
        )
        postponeItem.target = self
        postponeItem.representedObject = CalendarBreakAction.postpone.rawValue
        postponeItem.state = calendarPauseSettings.breakAction == .postpone ? .on : .off
        submenu.addItem(postponeItem)

        let skipItem = NSMenuItem(
            title: localized("smartPauseCalendarActionSkip"),
            action: #selector(selectCalendarBreakAction(_:)),
            keyEquivalent: ""
        )
        skipItem.target = self
        skipItem.representedObject = CalendarBreakAction.skip.rawValue
        skipItem.state = calendarPauseSettings.breakAction == .skip ? .on : .off
        submenu.addItem(skipItem)

        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(disabledMenuItem(localized("smartPauseCalendarCalendars")))

        if snapshot.permissionState != .authorized {
            submenu.addItem(disabledMenuItem(localized("smartPauseCalendarAccessRequired")))
        } else if snapshot.availableCalendars.isEmpty {
            submenu.addItem(disabledMenuItem(localized("smartPauseCalendarNoCalendars")))
        } else {
            let allCalendarsItem = NSMenuItem(
                title: localized("smartPauseCalendarAllCalendars"),
                action: #selector(selectAllCalendars),
                keyEquivalent: ""
            )
            allCalendarsItem.target = self
            allCalendarsItem.state = calendarPauseSettings.selectedCalendarIDs.isEmpty ? .on : .off
            submenu.addItem(allCalendarsItem)

            for calendar in snapshot.availableCalendars {
                let title = calendar.sourceTitle.isEmpty
                    ? calendar.title
                    : "\(calendar.title) (\(calendar.sourceTitle))"
                let item = NSMenuItem(
                    title: title,
                    action: #selector(toggleCalendarSelection(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = calendar.id
                item.state = calendarPauseSettings.selectedCalendarIDs.contains(calendar.id) ? .on : .off
                submenu.addItem(item)
            }
        }

        return submenu
    }

    private func buildExcludedAppsSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let excludedSet = MeetingAutoPausePolicy.normalizedExcludedSet(from: meetingAutoPauseSettings.excludedApps)

        if meetingAutoPauseSettings.excludedApps.isEmpty {
            submenu.addItem(disabledMenuItem(localized("smartPauseNoExcludedApps")))
        } else {
            submenu.addItem(disabledMenuItem(localized("smartPauseClickToRemove")))
            for appIdentifier in meetingAutoPauseSettings.excludedApps {
                let item = NSMenuItem(
                    title: appIdentifier,
                    action: #selector(removeExcludedApp(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = appIdentifier
                item.state = .on
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let selfBundleID = MeetingAutoPausePolicy.normalizedIdentifier(Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.activationPolicy != .prohibited {
            let frontBundle = frontmost.bundleIdentifier ?? ""
            let frontName = frontmost.localizedName ?? frontBundle
            let frontInfo = RunningAppInfo(bundleIdentifier: frontBundle, localizedName: frontName, isFrontmost: true)
            let isSelf = MeetingAutoPausePolicy.normalizedIdentifier(frontBundle) == selfBundleID
            if !isSelf,
               !frontName.isEmpty,
               !MeetingAutoPausePolicy.isExcluded(frontInfo, excludedSet: excludedSet) {
                let identifierToAdd = frontBundle.isEmpty ? frontName : frontBundle
                let title = String(format: localized("smartPauseAddFrontmostFormat"), frontName)
                let addFrontmostItem = NSMenuItem(
                    title: title,
                    action: #selector(addExcludedApp(_:)),
                    keyEquivalent: ""
                )
                addFrontmostItem.target = self
                addFrontmostItem.representedObject = identifierToAdd
                submenu.addItem(addFrontmostItem)
            }
        }

        let runningAppsItem = NSMenuItem(
            title: localized("smartPauseAddRunningApp"),
            action: nil,
            keyEquivalent: ""
        )
        let runningSubmenu = NSMenu()
        let candidateApps = MeetingCallMonitor.collectRunningApps()
            .filter { app in
                let normalizedBundle = MeetingAutoPausePolicy.normalizedIdentifier(app.bundleIdentifier)
                return normalizedBundle != selfBundleID &&
                    !MeetingAutoPausePolicy.isExcluded(app, excludedSet: excludedSet) &&
                    !app.localizedName.isEmpty
            }
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }

        if candidateApps.isEmpty {
            runningSubmenu.addItem(disabledMenuItem(localized("smartPauseNoRunningApps")))
        } else {
            for app in candidateApps {
                let identifierToAdd = app.bundleIdentifier.isEmpty ? app.localizedName : app.bundleIdentifier
                let title = app.bundleIdentifier.isEmpty ? app.localizedName : "\(app.localizedName) (\(app.bundleIdentifier))"
                let item = NSMenuItem(
                    title: title,
                    action: #selector(addExcludedApp(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = identifierToAdd
                runningSubmenu.addItem(item)
            }
        }
        runningAppsItem.submenu = runningSubmenu
        submenu.addItem(runningAppsItem)

        let addCustomItem = NSMenuItem(
            title: localized("smartPauseAddCustomApp"),
            action: #selector(promptAddCustomExcludedApp),
            keyEquivalent: ""
        )
        addCustomItem.target = self
        submenu.addItem(addCustomItem)

        return submenu
    }

    private func buildDeepFocusAppsSubmenu() -> NSMenu {
        let submenu = NSMenu()

        if focusAppPauseSettings.deepFocusApps.isEmpty {
            submenu.addItem(disabledMenuItem(localized("smartPauseNoDeepFocusApps")))
        } else {
            for rule in focusAppPauseSettings.deepFocusApps {
                let modeLabel = localized(
                    rule.triggerMode == .whenFrontmost
                        ? "smartPauseDeepFocusModeFrontmost"
                        : "smartPauseDeepFocusModeOpen"
                )
                let item = NSMenuItem(
                    title: "\(rule.effectiveDisplayName) (\(modeLabel))",
                    action: nil,
                    keyEquivalent: ""
                )
                item.state = .on
                let ruleSubmenu = NSMenu()

                let frontmostModeItem = NSMenuItem(
                    title: localized("smartPauseDeepFocusModeFrontmost"),
                    action: #selector(setDeepFocusModeFrontmost(_:)),
                    keyEquivalent: ""
                )
                frontmostModeItem.target = self
                frontmostModeItem.representedObject = rule.identifier
                frontmostModeItem.state = rule.triggerMode == .whenFrontmost ? .on : .off
                ruleSubmenu.addItem(frontmostModeItem)

                let openModeItem = NSMenuItem(
                    title: localized("smartPauseDeepFocusModeOpen"),
                    action: #selector(setDeepFocusModeOpen(_:)),
                    keyEquivalent: ""
                )
                openModeItem.target = self
                openModeItem.representedObject = rule.identifier
                openModeItem.state = rule.triggerMode == .whenOpen ? .on : .off
                ruleSubmenu.addItem(openModeItem)

                ruleSubmenu.addItem(NSMenuItem.separator())

                let removeItem = NSMenuItem(
                    title: localized("smartPauseDeepFocusRemove"),
                    action: #selector(removeDeepFocusApp(_:)),
                    keyEquivalent: ""
                )
                removeItem.target = self
                removeItem.representedObject = rule.identifier
                ruleSubmenu.addItem(removeItem)

                item.submenu = ruleSubmenu
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let selfBundleID = MeetingAutoPausePolicy.normalizedIdentifier(Bundle.main.bundleIdentifier ?? AppIdentity.bundleIdentifier)
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.activationPolicy != .prohibited {
            let frontBundle = frontmost.bundleIdentifier ?? ""
            let frontName = frontmost.localizedName ?? frontBundle
            let frontInfo = RunningAppInfo(bundleIdentifier: frontBundle, localizedName: frontName, isFrontmost: true)
            let isSelf = MeetingAutoPausePolicy.normalizedIdentifier(frontBundle) == selfBundleID
            if !isSelf,
               !frontName.isEmpty,
               !FocusAppPauseSettings.containsApp(frontInfo, in: focusAppPauseSettings.deepFocusApps) {
                let identifierToAdd = frontBundle.isEmpty ? frontName : frontBundle
                let title = String(format: localized("smartPauseAddFrontmostFormat"), frontName)
                let addFrontmostItem = NSMenuItem(
                    title: title,
                    action: #selector(addDeepFocusAppFromMenu(_:)),
                    keyEquivalent: ""
                )
                addFrontmostItem.target = self
                addFrontmostItem.representedObject = [identifierToAdd, frontName]
                submenu.addItem(addFrontmostItem)
            }
        }

        let runningAppsItem = NSMenuItem(
            title: localized("smartPauseAddRunningApp"),
            action: nil,
            keyEquivalent: ""
        )
        let runningSubmenu = NSMenu()
        let candidateApps = MeetingCallMonitor.collectRunningApps()
            .filter { app in
                let normalizedBundle = MeetingAutoPausePolicy.normalizedIdentifier(app.bundleIdentifier)
                return normalizedBundle != selfBundleID &&
                    !FocusAppPauseSettings.containsApp(app, in: focusAppPauseSettings.deepFocusApps) &&
                    !app.localizedName.isEmpty
            }
            .sorted { $0.localizedName.localizedCaseInsensitiveCompare($1.localizedName) == .orderedAscending }

        if candidateApps.isEmpty {
            runningSubmenu.addItem(disabledMenuItem(localized("smartPauseNoRunningApps")))
        } else {
            for app in candidateApps {
                let identifierToAdd = app.bundleIdentifier.isEmpty ? app.localizedName : app.bundleIdentifier
                let title = app.bundleIdentifier.isEmpty ? app.localizedName : "\(app.localizedName) (\(app.bundleIdentifier))"
                let item = NSMenuItem(
                    title: title,
                    action: #selector(addDeepFocusAppFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = [identifierToAdd, app.localizedName]
                runningSubmenu.addItem(item)
            }
        }
        runningAppsItem.submenu = runningSubmenu
        submenu.addItem(runningAppsItem)

        let addCustomItem = NSMenuItem(
            title: localized("smartPauseAddCustomApp"),
            action: #selector(promptAddCustomDeepFocusApp),
            keyEquivalent: ""
        )
        addCustomItem.target = self
        submenu.addItem(addCustomItem)

        return submenu
    }

    private func buildMaxWaitThresholdSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let currentSeconds = Int(inputDeferralSettings.maxWaitThreshold)
        for seconds in InputDeferralSettings.supportedMaxWaitThresholds {
            let key: String
            switch seconds {
            case 30:
                key = "smartPauseMaxWait30"
            case 120:
                key = "smartPauseMaxWait120"
            default:
                key = "smartPauseMaxWait60"
            }
            let item = NSMenuItem(
                title: localized(key),
                action: #selector(selectMaxWaitThreshold(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = seconds
            item.state = currentSeconds == seconds ? .on : .off
            item.isEnabled = inputDeferralSettings.isEnabled
            submenu.addItem(item)
        }
        return submenu
    }

    private func buildIdleThresholdSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let currentSeconds = Int(idleNaturalBreakSettings.idlePauseThreshold)
        for seconds in IdleNaturalBreakSettings.supportedIdleThresholds {
            let key: String
            switch seconds {
            case 60:
                key = "smartPauseIdleThreshold60"
            case 300:
                key = "smartPauseIdleThreshold300"
            default:
                key = "smartPauseIdleThreshold120"
            }
            let item = NSMenuItem(
                title: localized(key),
                action: #selector(selectIdleThreshold(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = seconds
            item.state = currentSeconds == seconds ? .on : .off
            item.isEnabled = idleNaturalBreakSettings.isEnabled
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func toggleScreenCapturePause() {
        screenCaptureSettings.isEnabled.toggle()
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    private func syncCalendarEventMonitorState() {
        if calendarPauseSettings.isEnabled || calendarBreakSettings.isEnabled {
            calendarEventMonitor.start()
        } else {
            calendarEventMonitor.stop()
        }
    }

    @objc private func toggleCalendarPause() {
        let nextEnabled = !calendarPauseSettings.isEnabled
        calendarPauseSettings.isEnabled = nextEnabled
        saveSettings()
        syncCalendarEventMonitorState()

        if nextEnabled && calendarEventMonitor.currentSnapshot().permissionState == .notDetermined {
            calendarEventMonitor.requestAccess { [weak self] _ in
                self?.rebuildSmartPauseMenu()
                self?.rebuildCalendarBreaksMenu()
                self?.evaluateSmartPause(refreshSnapshots: true)
            }
            return
        }

        rebuildSmartPauseMenu()
        rebuildCalendarBreaksMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func requestCalendarAccess() {
        calendarEventMonitor.requestAccess { [weak self] _ in
            self?.rebuildSmartPauseMenu()
            self?.rebuildCalendarBreaksMenu()
            self?.evaluateSmartPause(refreshSnapshots: true)
            self?.rescheduleCountdown()
        }
    }

    @objc private func openCalendarSettings() {
        calendarEventMonitor.openCalendarPrivacySettings()
    }

    @objc private func selectCalendarBreakAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = CalendarBreakAction(rawValue: rawValue) else {
            return
        }
        calendarPauseSettings.breakAction = action
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func selectAllCalendars() {
        calendarPauseSettings.selectedCalendarIDs.removeAll()
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func toggleCalendarSelection(_ sender: NSMenuItem) {
        guard let calendarID = sender.representedObject as? String else { return }
        if calendarPauseSettings.selectedCalendarIDs.contains(calendarID) {
            calendarPauseSettings.selectedCalendarIDs.remove(calendarID)
        } else {
            calendarPauseSettings.selectedCalendarIDs.insert(calendarID)
        }
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func toggleMeetingAutoPause() {
        meetingAutoPauseSettings.isEnabled.toggle()
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func toggleFullscreenPause() {
        focusAppPauseSettings.fullscreenPauseEnabled.toggle()
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func toggleWaitForInput() {
        inputDeferralSettings.isEnabled.toggle()
        saveSettings()
        rebuildSmartPauseMenu()
        if !inputDeferralSettings.isEnabled && isWaitingForInputDeferral {
            showBreakOverlay()
        }
    }

    @objc private func selectMaxWaitThreshold(_ sender: NSMenuItem) {
        let validated = InputDeferralSettings.validatedMaxWaitSeconds(sender.tag)
        inputDeferralSettings.maxWaitThreshold = TimeInterval(validated)
        saveSettings()
        rebuildSmartPauseMenu()
        if isWaitingForInputDeferral {
            showBreakOverlay()
        }
    }

    @objc private func toggleIdlePause() {
        idleNaturalBreakSettings.isEnabled.toggle()
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func selectIdleThreshold(_ sender: NSMenuItem) {
        let validated = IdleNaturalBreakSettings.supportedIdleThresholds.contains(sender.tag)
            ? sender.tag
            : Int(IdleNaturalBreakSettings.defaultIdlePauseThreshold)
        idleNaturalBreakSettings.idlePauseThreshold = TimeInterval(validated)
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func addExcludedApp(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        meetingAutoPauseSettings.excludedApps = MeetingAutoPausePolicy.addingExcludedApp(
            identifier,
            to: meetingAutoPauseSettings.excludedApps
        )
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func removeExcludedApp(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        meetingAutoPauseSettings.excludedApps = MeetingAutoPausePolicy.removingExcludedApp(
            identifier,
            from: meetingAutoPauseSettings.excludedApps
        )
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func promptAddCustomExcludedApp() {
        let alert = NSAlert()
        alert.messageText = localized("smartPauseAddAppTitle")
        alert.informativeText = localized("smartPauseAddAppMessage")
        alert.addButton(withTitle: localized("smartPauseAdd"))
        alert.addButton(withTitle: localized("nightOverrideCancel"))

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        inputField.placeholderString = localized("smartPauseAddAppPlaceholder")
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let value = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        meetingAutoPauseSettings.excludedApps = MeetingAutoPausePolicy.addingExcludedApp(
            value,
            to: meetingAutoPauseSettings.excludedApps
        )
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func addDeepFocusAppFromMenu(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String], let identifier = payload.first else { return }
        let displayName = payload.count > 1 ? payload[1] : nil
        let rule = DeepFocusAppRule(
            identifier: identifier,
            displayName: displayName,
            triggerMode: .whenFrontmost
        )
        focusAppPauseSettings.deepFocusApps = FocusAppPauseSettings.addingRule(
            rule,
            to: focusAppPauseSettings.deepFocusApps
        )
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func setDeepFocusModeFrontmost(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        focusAppPauseSettings.deepFocusApps = FocusAppPauseSettings.updatingTriggerMode(
            .whenFrontmost,
            for: identifier,
            in: focusAppPauseSettings.deepFocusApps
        )
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func setDeepFocusModeOpen(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        focusAppPauseSettings.deepFocusApps = FocusAppPauseSettings.updatingTriggerMode(
            .whenOpen,
            for: identifier,
            in: focusAppPauseSettings.deepFocusApps
        )
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func removeDeepFocusApp(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        focusAppPauseSettings.deepFocusApps = FocusAppPauseSettings.removingRule(
            identifier: identifier,
            from: focusAppPauseSettings.deepFocusApps
        )
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    @objc private func promptAddCustomDeepFocusApp() {
        let alert = NSAlert()
        alert.messageText = localized("smartPauseAddDeepFocusTitle")
        alert.informativeText = localized("smartPauseAddDeepFocusMessage")
        alert.addButton(withTitle: localized("smartPauseAdd"))
        alert.addButton(withTitle: localized("nightOverrideCancel"))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 58))
        let inputField = NSTextField(frame: NSRect(x: 0, y: 34, width: 280, height: 24))
        inputField.placeholderString = localized("smartPauseAddAppPlaceholder")

        let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        modePopup.addItems(withTitles: [
            localized("smartPauseDeepFocusModeFrontmost"),
            localized("smartPauseDeepFocusModeOpen")
        ])

        container.addSubview(inputField)
        container.addSubview(modePopup)
        alert.accessoryView = container
        alert.window.initialFirstResponder = inputField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let value = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let mode: DeepFocusTriggerMode = modePopup.indexOfSelectedItem == 1 ? .whenOpen : .whenFrontmost
        let rule = DeepFocusAppRule(identifier: value, triggerMode: mode)
        focusAppPauseSettings.deepFocusApps = FocusAppPauseSettings.addingRule(
            rule,
            to: focusAppPauseSettings.deepFocusApps
        )
        saveSettings()
        rebuildSmartPauseMenu()
        evaluateSmartPause(refreshSnapshots: true)
    }

    private func smartPauseMenuStatusText() -> String {
        guard let reason = smartPauseEvaluation.reason else {
            return localized("smartPauseMenuMeeting")
        }
        switch reason {
        case .screenRecordingOrSharing(let source):
            if let source, !source.isEmpty {
                return String(format: localized("smartPauseMenuScreenCaptureFormat"), source)
            }
            return localized("smartPauseMenuScreenCapture")
        case .meetingOrCall(let appName):
            if let appName, !appName.isEmpty {
                return String(format: localized("smartPauseMenuMeetingFormat"), appName)
            }
            return localized("smartPauseMenuMeeting")
        case .calendarEvent(let title):
            if let title, !title.isEmpty {
                return String(format: localized("smartPauseMenuCalendarFormat"), title)
            }
            return localized("smartPauseMenuCalendar")
        case .fullscreenApp(let appName):
            if let appName, !appName.isEmpty {
                return String(format: localized("smartPauseMenuFullscreenFormat"), appName)
            }
            return localized("smartPauseMenuFullscreen")
        case .deepFocusApp(let appName):
            if let appName, !appName.isEmpty {
                return String(format: localized("smartPauseMenuDeepFocusFormat"), appName)
            }
            return localized("smartPauseMenuDeepFocus")
        case .typingOrDragging:
            return inputDeferralMenuStatusText()
        case .userIdle:
            return localized("smartPauseMenuIdle")
        }
    }

    private func inputDeferralMenuStatusText() -> String {
        switch inputDeferralReason {
        case .typing:
            return localized("smartPauseMenuWaitingTyping")
        case .dragging:
            return localized("smartPauseMenuWaitingDragging")
        case .typingAndDragging, .none:
            return localized("smartPauseMenuWaitingInput")
        }
    }

    private func shouldDeferBreakForInputActivity() -> Bool {
        let now = Date()
        let startedAt = inputDeferralStartedAt ?? now
        let waitDuration = now.timeIntervalSince(startedAt)
        let activity = inputActivityProvider.currentActivity(now: now)
        let decision = inputDeferralPolicy.evaluate(
            settings: inputDeferralSettings,
            activity: activity,
            waitDuration: waitDuration
        )

        switch decision {
        case .triggerNow:
            return false
        case .deferBreak(let reason, let recheckAfter):
            if inputDeferralStartedAt == nil {
                inputDeferralStartedAt = startedAt
                logSessionDebug("break_deferred_for_input", context: [
                    "reason": "\(reason)",
                    "max_wait_seconds": "\(Int(inputDeferralSettings.maxWaitThreshold))"
                ])
            }
            inputDeferralReason = reason
            workSessionStartTime = nil
            postponeStartTime = nil
            postponeDuration = 0
            scheduleInputDeferralRecheck(after: recheckAfter)
            updateStatusBarTitle(now: now)
            updateMenuTimer(now: now)
            rescheduleCountdown()
            return true
        }
    }

    private func scheduleInputDeferralRecheck(after interval: TimeInterval) {
        inputDeferralTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.1, interval), repeats: false) { [weak self] _ in
            self?.handleInputDeferralRecheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        inputDeferralTimer = timer
    }

    private func handleInputDeferralRecheck() {
        inputDeferralTimer = nil
        guard isWaitingForInputDeferral else { return }
        showBreakOverlay()
    }

    private func cancelInputDeferral() {
        inputDeferralTimer?.invalidate()
        inputDeferralTimer = nil
        inputDeferralStartedAt = nil
        inputDeferralReason = nil
    }

    private func evaluateSmartPause(refreshSnapshots: Bool = false) {
        let screenCaptureSnapshot = refreshSnapshots ? screenCaptureMonitor.currentSnapshot() : screenCaptureMonitor.lastSnapshot
        let meetingSnapshot = refreshSnapshots ? meetingCallMonitor.currentSnapshot() : meetingCallMonitor.lastSnapshot
        let calendarSnapshot = refreshSnapshots ? calendarEventMonitor.currentSnapshot() : calendarEventMonitor.lastSnapshot
        let focusSnapshot = refreshSnapshots ? focusAppMonitor.currentSnapshot() : focusAppMonitor.lastSnapshot
        let runningApps = focusSnapshot.runningApps.isEmpty ? meetingSnapshot.runningApps : focusSnapshot.runningApps

        let nonIdleEvaluation = smartPausePolicy.evaluate(
            screenCaptureSettings: screenCaptureSettings,
            screenCaptureSnapshot: screenCaptureSnapshot,
            meetingSettings: meetingAutoPauseSettings,
            calendarSettings: calendarPauseSettings,
            calendarBreakSettings: calendarBreakSettings,
            calendarSnapshot: calendarSnapshot,
            focusAppSettings: focusAppPauseSettings,
            idleSettings: IdleNaturalBreakSettings(isEnabled: false),
            idleState: .active,
            isAudioInputActive: meetingSnapshot.isAudioInputActive,
            isFrontmostFullscreen: focusSnapshot.isFrontmostFullscreen,
            runningApps: runningApps
        )

        let idleSeconds = refreshSnapshots ? idleMonitor.currentIdleSeconds() : idleMonitor.lastIdleSeconds
        let effectiveIdleSettings = IdleNaturalBreakSettings(
            isEnabled: idleNaturalBreakSettings.isEnabled,
            idlePauseThreshold: idleNaturalBreakSettings.idlePauseThreshold,
            naturalBreakDuration: idleNaturalBreakSettings.idlePauseThreshold + TimeInterval(max(1, currentBreakDuration))
        )
        let isFullscreenOrVideoActive = nonIdleEvaluation.isFullscreenOrVideoActive || focusSnapshot.isFrontmostFullscreen
        let idleResult = idleNaturalBreakPolicy.evaluate(
            settings: effectiveIdleSettings,
            currentState: idleState,
            idleSeconds: idleSeconds,
            isFullscreenOrVideoActive: isFullscreenOrVideoActive,
            isOtherSmartPauseActive: nonIdleEvaluation.isPaused
        )
        idleState = idleResult.nextState

        if idleResult.transition == .creditNaturalBreakAndReset {
            smartPauseSnapshot?.shouldResetToFreshWorkOnResume = true
            smartPauseSnapshot?.hadDeferredBreak = false
            logSessionDebug("idle_natural_break_credited", context: [
                "idle_threshold_seconds": "\(Int(effectiveIdleSettings.idlePauseThreshold))",
                "natural_break_seconds": "\(Int(effectiveIdleSettings.effectiveNaturalBreakDuration))"
            ])
        }

        let nextEvaluation = smartPausePolicy.evaluate(
            screenCaptureSettings: screenCaptureSettings,
            screenCaptureSnapshot: screenCaptureSnapshot,
            meetingSettings: meetingAutoPauseSettings,
            calendarSettings: calendarPauseSettings,
            calendarBreakSettings: calendarBreakSettings,
            calendarSnapshot: calendarSnapshot,
            focusAppSettings: focusAppPauseSettings,
            idleSettings: effectiveIdleSettings,
            idleState: idleState,
            isAudioInputActive: meetingSnapshot.isAudioInputActive,
            isFrontmostFullscreen: focusSnapshot.isFrontmostFullscreen,
            runningApps: runningApps
        )
        applySmartPauseEvaluation(nextEvaluation)

        let now = Date()
        let awayInterval: DateInterval?
        if idleResult.transition == .creditNaturalBreakAndReset || idleState.isIdlePaused {
            awayInterval = DateInterval(start: now.addingTimeInterval(-max(0, idleSeconds)), end: now)
        } else {
            awayInterval = nil
        }
        _ = evaluatePlannedBreaks(now: now, awayInterval: awayInterval)
        _ = evaluateCalendarBreaks(now: now, awayInterval: awayInterval)
    }

    private func applySmartPauseEvaluation(_ nextEvaluation: SmartPauseEvaluation) {
        let wasPaused = smartPauseEvaluation.isPaused
        smartPauseEvaluation = nextEvaluation

        if currentNightStatus().isLocked || isTemporaryDisableActive {
            if !nextEvaluation.isPaused {
                smartPauseSnapshot = nil
            }
            updateStatusBarTitle()
            updateMenuTimer()
            return
        }

        if !wasPaused && nextEvaluation.isPaused {
            enterSmartPause()
        } else if wasPaused && !nextEvaluation.isPaused {
            leaveSmartPause()
        } else if nextEvaluation.isPaused {
            if isSkippingCalendarBreakActive {
                smartPauseSnapshot?.shouldResetToFreshWorkOnResume = true
                smartPauseSnapshot?.hadDeferredBreak = false
            }
            updateStatusBarTitle()
            updateMenuTimer()
        }
    }

    private func enterSmartPause() {
        guard displaysAreActive else { return }
        let wasWaitingForInputDeferral = isWaitingForInputDeferral
        cancelInputDeferral()
        dismissPreBreakHUD()
        countdownScheduler.cancel()

        if let breakStart = breakSessionStartTime {
            let elapsed = Date().timeIntervalSince(breakStart)
            logManager.logBreakCompleted(actualDuration: elapsed, expectedDuration: currentBreakDuration)
            eventRecorder.endBreakSession()
            cleanupBreakOverlays()
            breakSessionStartTime = nil
            if activePlannedBreakOccurrence != nil {
                activePlannedBreakOccurrence = nil
                plannedBreakState.activeOccurrence = nil
                activeBreakDurationOverrideSeconds = nil
            }
            if activeCalendarBreakOccurrence != nil {
                activeCalendarBreakOccurrence = nil
                calendarBreakState.activeOccurrence = nil
                activeBreakDurationOverrideSeconds = nil
            }
            if isSkippingCalendarBreakActive {
                workSessionStartTime = nil
                postponeStartTime = nil
                postponeDuration = 0
                smartPauseSnapshot = SmartPauseSnapshot(
                    remainingWorkTime: nil,
                    remainingPostponeTime: nil,
                    hadDeferredBreak: false,
                    shouldResetToFreshWorkOnResume: true
                )
            } else {
                smartPauseSnapshot = SmartPauseSnapshot(
                    remainingWorkTime: nil,
                    remainingPostponeTime: nil,
                    hadDeferredBreak: true
                )
            }
        } else if isSkippingCalendarBreakActive {
            workSessionStartTime = nil
            postponeStartTime = nil
            postponeDuration = 0
            smartPauseSnapshot = SmartPauseSnapshot(
                remainingWorkTime: nil,
                remainingPostponeTime: nil,
                hadDeferredBreak: false,
                shouldResetToFreshWorkOnResume: true
            )
        } else if wasWaitingForInputDeferral {
            smartPauseSnapshot = SmartPauseSnapshot(
                remainingWorkTime: nil,
                remainingPostponeTime: nil,
                hadDeferredBreak: true
            )
        } else if postponeStartTime != nil {
            let remaining = postponeTimeRemaining
            postponeStartTime = nil
            postponeDuration = 0
            smartPauseSnapshot = SmartPauseSnapshot(
                remainingWorkTime: nil,
                remainingPostponeTime: remaining > 0 ? remaining : nil,
                hadDeferredBreak: remaining <= 0
            )
        } else if workSessionStartTime != nil {
            let remaining = workTimeRemaining
            workSessionStartTime = nil
            smartPauseSnapshot = SmartPauseSnapshot(
                remainingWorkTime: remaining > 0 ? remaining : nil,
                remainingPostponeTime: nil,
                hadDeferredBreak: remaining <= 0
            )
        } else {
            smartPauseSnapshot = SmartPauseSnapshot(
                remainingWorkTime: nil,
                remainingPostponeTime: nil,
                hadDeferredBreak: false
            )
        }

        saveCurrentSessionState()
        updateStatusBarTitle()
        updateMenuTimer()
        rescheduleCountdown()
    }

    private func leaveSmartPause() {
        let snapshot = smartPauseSnapshot
        smartPauseSnapshot = nil
        guard displaysAreActive else { return }

        if applyNightRestrictionState(reason: "smart_pause_ended") {
            rescheduleCountdown()
            return
        }
        if isTemporaryDisableActive {
            rescheduleCountdown()
            return
        }

        if snapshot?.shouldResetToFreshWorkOnResume == true {
            startWorkTimer(forceFreshSession: true)
        } else if evaluatePlannedBreaks(now: Date()) {
            return
        } else if snapshot?.hadDeferredBreak == true {
            showBreakOverlay()
        } else if let remainingPostpone = snapshot?.remainingPostponeTime, remainingPostpone > 0 {
            postponeStartTime = Date()
            postponeDuration = remainingPostpone
            saveCurrentSessionState()
            updateStatusBarTitle()
            updateMenuTimer()
            rescheduleCountdown()
        } else if let remainingWork = snapshot?.remainingWorkTime, remainingWork > 0 {
            let planned = TimeInterval(effectiveWorkDuration)
            let elapsed = max(0, planned - remainingWork)
            workSessionStartTime = Date().addingTimeInterval(-elapsed)
            saveCurrentSessionState()
            updateStatusBarTitle()
            updateMenuTimer()
            rescheduleCountdown()
        } else {
            startWorkTimer()
        }
    }

    // MARK: - Planned Breaks

    private func shouldSuppressRegularBreakForPlannedBreak(now: Date = Date()) -> Bool {
        let evaluation = plannedBreakPolicy.evaluate(
            settings: plannedBreakSettings,
            state: plannedBreakState,
            now: now,
            smartPauseEvaluation: smartPauseEvaluation,
            isNightLocked: currentNightStatus(now: now).isLocked,
            isTemporarilyDisabled: isTemporaryDisableActive
        )
        return evaluation.shouldSuppressRegularBreak
    }

    @discardableResult
    private func evaluatePlannedBreaks(now: Date = Date(), awayInterval: DateInterval? = nil) -> Bool {
        guard displaysAreActive else { return false }
        let status = currentNightStatus(now: now)
        let evaluation = plannedBreakPolicy.evaluate(
            settings: plannedBreakSettings,
            state: plannedBreakState,
            now: now,
            smartPauseEvaluation: smartPauseEvaluation,
            awayInterval: awayInterval,
            isNightLocked: status.isLocked,
            isTemporarilyDisabled: isTemporaryDisableActive
        )
        plannedBreakState = evaluation.nextState

        switch evaluation.decision {
        case .trigger(let occurrence, let remainingSeconds):
            triggerPlannedBreak(occurrence, remainingSeconds: remainingSeconds)
            return true
        case .creditedAway(let occurrence):
            logSessionDebug("planned_break_credited_away", context: [
                "name": occurrence.schedule.name,
                "start_time": occurrence.schedule.formattedStartTime
            ])
            startWorkTimer(forceFreshSession: true)
            return true
        case .deferredBySmartPause(let occurrence, let reason):
            logSessionDebug("planned_break_deferred_smart_pause", context: [
                "name": occurrence.schedule.name,
                "reason": "\(String(describing: reason))"
            ])
            return false
        case .expired(let occurrence):
            logSessionDebug("planned_break_expired", context: [
                "name": occurrence.schedule.name
            ])
            return false
        case .none:
            return false
        }
    }

    private func triggerPlannedBreak(_ occurrence: PlannedBreakOccurrence, remainingSeconds: Int) {
        activePlannedBreakOccurrence = occurrence
        plannedBreakState.activeOccurrence = occurrence
        activeBreakDurationOverrideSeconds = max(PlannedBreakSchedule.minimumDurationSeconds, remainingSeconds)
        logSessionDebug("planned_break_triggered", context: [
            "name": occurrence.schedule.name,
            "duration_seconds": "\(activeBreakDurationOverrideSeconds ?? occurrence.schedule.durationSeconds)"
        ])
        showBreakOverlay(bypassInputDeferral: true)
    }

    private func setupPlannedBreaksMenu() {
        plannedBreaksMenuItem = NSMenuItem(title: localized("plannedBreaks"), action: nil, keyEquivalent: "")
        plannedBreaksMenuItem.submenu = buildPlannedBreaksSubmenu()
        menu.addItem(plannedBreaksMenuItem)
    }

    private func rebuildPlannedBreaksMenu() {
        guard plannedBreaksMenuItem != nil else { return }
        plannedBreaksMenuItem.title = localized("plannedBreaks")
        plannedBreaksMenuItem.submenu = buildPlannedBreaksSubmenu()
    }

    private func buildPlannedBreaksSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let sortedSchedules = plannedBreakSettings.schedules.sorted {
            if $0.hour != $1.hour { return $0.hour < $1.hour }
            if $0.minute != $1.minute { return $0.minute < $1.minute }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        if sortedSchedules.isEmpty {
            submenu.addItem(disabledMenuItem(localized("plannedBreaksNone")))
        } else {
            for schedule in sortedSchedules {
                let displayName = schedule.name.isEmpty ? localized("plannedBreakDefaultName") : schedule.name
                let title = String(
                    format: localized("plannedBreakMenuItemFormat"),
                    displayName,
                    schedule.formattedStartTime,
                    schedule.durationMinutes
                )
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.state = schedule.isEnabled ? .on : .off

                let itemSubmenu = NSMenu()
                let toggleItem = NSMenuItem(
                    title: localized("plannedBreakEnabled"),
                    action: #selector(togglePlannedBreakEnabled(_:)),
                    keyEquivalent: ""
                )
                toggleItem.target = self
                toggleItem.representedObject = schedule.id.uuidString
                toggleItem.state = schedule.isEnabled ? .on : .off
                itemSubmenu.addItem(toggleItem)

                let editItem = NSMenuItem(
                    title: localized("plannedBreakEdit"),
                    action: #selector(editPlannedBreak(_:)),
                    keyEquivalent: ""
                )
                editItem.target = self
                editItem.representedObject = schedule.id.uuidString
                itemSubmenu.addItem(editItem)

                itemSubmenu.addItem(NSMenuItem.separator())

                let deleteItem = NSMenuItem(
                    title: localized("plannedBreakDelete"),
                    action: #selector(deletePlannedBreak(_:)),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                deleteItem.representedObject = schedule.id.uuidString
                itemSubmenu.addItem(deleteItem)

                item.submenu = itemSubmenu
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let addItem = NSMenuItem(
            title: localized("plannedBreakAdd"),
            action: #selector(addPlannedBreak),
            keyEquivalent: ""
        )
        addItem.target = self
        submenu.addItem(addItem)

        return submenu
    }

    @objc private func addPlannedBreak() {
        promptPlannedBreakEditor(existing: nil)
    }

    @objc private func editPlannedBreak(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString),
              let existing = plannedBreakSettings.schedules.first(where: { $0.id == id }) else {
            return
        }
        promptPlannedBreakEditor(existing: existing)
    }

    @objc private func togglePlannedBreakEnabled(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else {
            return
        }
        plannedBreakSettings.toggle(id: id)
        saveSettings()
        rebuildPlannedBreaksMenu()
        _ = evaluatePlannedBreaks()
        rescheduleCountdown()
    }

    @objc private func deletePlannedBreak(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else {
            return
        }
        plannedBreakSettings.remove(id: id)
        if activePlannedBreakOccurrence?.schedule.id == id {
            activePlannedBreakOccurrence = nil
            activeBreakDurationOverrideSeconds = nil
            plannedBreakState.activeOccurrence = nil
        }
        saveSettings()
        rebuildPlannedBreaksMenu()
        rescheduleCountdown()
    }

    private func promptPlannedBreakEditor(existing: PlannedBreakSchedule?) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? localized("plannedBreakCreateTitle") : localized("plannedBreakEditTitle")
        alert.addButton(withTitle: localized("plannedBreakSave"))
        alert.addButton(withTitle: localized("nightOverrideCancel"))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 196))

        let nameLabel = NSTextField(labelWithString: localized("plannedBreakNameLabel"))
        nameLabel.frame = NSRect(x: 0, y: 172, width: 120, height: 18)
        let nameField = NSTextField(frame: NSRect(x: 0, y: 144, width: 340, height: 24))
        nameField.placeholderString = localized("plannedBreakNamePlaceholder")
        nameField.stringValue = existing?.name ?? ""

        let timeLabel = NSTextField(labelWithString: localized("plannedBreakStartTimeLabel"))
        timeLabel.frame = NSRect(x: 0, y: 112, width: 150, height: 18)
        let timePicker = NSDatePicker(frame: NSRect(x: 0, y: 84, width: 140, height: 24))
        timePicker.datePickerStyle = .textFieldAndStepper
        timePicker.datePickerElements = .hourMinute
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = existing?.hour ?? 12
        components.minute = existing?.minute ?? 0
        components.second = 0
        timePicker.dateValue = Calendar.current.date(from: components) ?? Date()

        let durationLabel = NSTextField(labelWithString: localized("plannedBreakDurationLabel"))
        durationLabel.frame = NSRect(x: 170, y: 112, width: 170, height: 18)
        let durationField = NSTextField(frame: NSRect(x: 170, y: 84, width: 80, height: 24))
        let initialMinutes = existing?.durationMinutes ?? 15
        durationField.integerValue = initialMinutes
        let durationStepper = NSStepper(frame: NSRect(x: 256, y: 82, width: 20, height: 26))
        durationStepper.minValue = 1
        durationStepper.maxValue = 180
        durationStepper.integerValue = initialMinutes
        durationStepper.target = durationField
        durationStepper.action = #selector(NSTextField.takeIntegerValueFrom(_:))

        let weekdaysLabel = NSTextField(labelWithString: localized("plannedBreakWeekdaysLabel"))
        weekdaysLabel.frame = NSRect(x: 0, y: 54, width: 200, height: 18)

        let shortSymbols = Calendar.current.shortWeekdaySymbols
        let selectedWeekdays = existing?.weekdays ?? PlannedBreakSchedule.workWeekdays
        var weekdayCheckboxes: [Int: NSButton] = [:]
        let buttonWidth: CGFloat = 46
        for dayIndex in 1...7 {
            let symbol = (dayIndex - 1 < shortSymbols.count) ? shortSymbols[dayIndex - 1] : "\(dayIndex)"
            let checkbox = NSButton(checkboxWithTitle: symbol, target: nil, action: nil)
            checkbox.frame = NSRect(x: CGFloat(dayIndex - 1) * (buttonWidth + 2), y: 20, width: buttonWidth, height: 24)
            checkbox.state = selectedWeekdays.contains(dayIndex) ? .on : .off
            container.addSubview(checkbox)
            weekdayCheckboxes[dayIndex] = checkbox
        }

        container.addSubview(nameLabel)
        container.addSubview(nameField)
        container.addSubview(timeLabel)
        container.addSubview(timePicker)
        container.addSubview(durationLabel)
        container.addSubview(durationField)
        container.addSubview(durationStepper)
        container.addSubview(weekdaysLabel)

        alert.accessoryView = container
        alert.window.initialFirstResponder = nameField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? localized("plannedBreakDefaultName") : trimmedName
        let pickedComponents = Calendar.current.dateComponents([.hour, .minute], from: timePicker.dateValue)
        let hour = pickedComponents.hour ?? 12
        let minute = pickedComponents.minute ?? 0
        let durationMinutes = min(180, max(1, durationField.integerValue > 0 ? durationField.integerValue : durationStepper.integerValue))
        var weekdays: Set<Int> = []
        for (dayIndex, checkbox) in weekdayCheckboxes where checkbox.state == .on {
            weekdays.insert(dayIndex)
        }

        let schedule = PlannedBreakSchedule(
            id: existing?.id ?? UUID(),
            name: finalName,
            hour: hour,
            minute: minute,
            durationMinutes: durationMinutes,
            weekdays: weekdays,
            isEnabled: existing?.isEnabled ?? true
        )

        if existing != nil {
            plannedBreakSettings.update(schedule)
        } else {
            plannedBreakSettings.add(schedule)
        }
        saveSettings()
        rebuildPlannedBreaksMenu()
        _ = evaluatePlannedBreaks()
        rescheduleCountdown()
    }

    // MARK: - Calendar Breaks

    @discardableResult
    private func evaluateCalendarBreaks(now: Date = Date(), awayInterval: DateInterval? = nil) -> Bool {
        guard displaysAreActive else { return false }
        let status = currentNightStatus(now: now)
        let snapshot = calendarEventMonitor.lastSnapshot
        let evaluation = calendarBreakPolicy.evaluate(
            settings: calendarBreakSettings,
            snapshot: snapshot,
            state: calendarBreakState,
            now: now,
            smartPauseEvaluation: smartPauseEvaluation,
            awayInterval: awayInterval,
            isNightLocked: status.isLocked,
            isTemporarilyDisabled: isTemporaryDisableActive
        )
        calendarBreakState = evaluation.nextState

        // Remember the latest calendar title if it's currently visible.
        if let selectedID = calendarBreakSettings.selectedCalendarID,
           let matchedCalendar = snapshot.availableCalendars.first(where: { $0.id == selectedID }),
           calendarBreakSettings.selectedCalendarTitle != matchedCalendar.title {
            calendarBreakSettings.selectedCalendarTitle = matchedCalendar.title
        }

        switch evaluation.decision {
        case .trigger(let occurrence, let remainingSeconds),
             .resumePostponed(let occurrence, let remainingSeconds):
            triggerCalendarBreak(occurrence, remainingSeconds: remainingSeconds)
            return true
        case .creditedAway(let occurrence):
            logSessionDebug("calendar_break_credited_away", context: [
                "title": occurrence.title
            ])
            startWorkTimer(forceFreshSession: true)
            return true
        case .deferredBySmartPause(let occurrence, let reason):
            logSessionDebug("calendar_break_deferred_smart_pause", context: [
                "title": occurrence.title,
                "reason": "\(String(describing: reason))"
            ])
            return false
        case .expired(let occurrence):
            logSessionDebug("calendar_break_expired", context: [
                "title": occurrence.title
            ])
            if postponeStartTime != nil {
                postponeStartTime = nil
                postponeDuration = 0
                startWorkTimer(forceFreshSession: true)
                return true
            }
            return false
        case .activeEventRemoved(let occurrence):
            logSessionDebug("calendar_break_event_removed", context: [
                "title": occurrence.title
            ])
            if activeCalendarBreakOccurrence?.occurrenceKey == occurrence.occurrenceKey {
                activeCalendarBreakOccurrence = nil
                activeBreakDurationOverrideSeconds = nil
                if breakSessionStartTime != nil {
                    countdownScheduler.cancel()
                    cleanupBreakOverlays()
                    breakSessionStartTime = nil
                    eventRecorder.endBreakSession()
                    startWorkTimer(forceFreshSession: true)
                    return true
                }
            } else if postponeStartTime != nil {
                postponeStartTime = nil
                postponeDuration = 0
                startWorkTimer(forceFreshSession: true)
                return true
            }
            return false
        case .none:
            return false
        }
    }

    private func triggerCalendarBreak(_ occurrence: CalendarBreakOccurrence, remainingSeconds: Int) {
        postponeStartTime = nil
        postponeDuration = 0
        activeCalendarBreakOccurrence = occurrence
        calendarBreakState.activeOccurrence = occurrence
        activeBreakDurationOverrideSeconds = max(1, remainingSeconds)
        logSessionDebug("calendar_break_triggered", context: [
            "title": occurrence.title,
            "duration_seconds": "\(activeBreakDurationOverrideSeconds ?? occurrence.durationSeconds)"
        ])
        showBreakOverlay(bypassInputDeferral: true)
    }

    private func setupCalendarBreaksMenu() {
        calendarBreaksMenuItem = NSMenuItem(title: localized("calendarBreaks"), action: nil, keyEquivalent: "")
        calendarBreaksMenuItem.submenu = buildCalendarBreaksSubmenu()
        menu.addItem(calendarBreaksMenuItem)
    }

    private func rebuildCalendarBreaksMenu() {
        guard calendarBreaksMenuItem != nil else { return }
        calendarBreaksMenuItem.title = localized("calendarBreaks")
        calendarBreaksMenuItem.submenu = buildCalendarBreaksSubmenu()
    }

    private func buildCalendarBreaksSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let snapshot = calendarEventMonitor.currentSnapshot()

        let enabledItem = NSMenuItem(
            title: localized("calendarBreaksEnabled"),
            action: #selector(toggleCalendarBreaks),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = calendarBreakSettings.isEnabled ? .on : .off
        submenu.addItem(enabledItem)

        switch snapshot.permissionState {
        case .notDetermined:
            let grantItem = NSMenuItem(
                title: localized("smartPauseCalendarGrantAccess"),
                action: #selector(requestCalendarAccess),
                keyEquivalent: ""
            )
            grantItem.target = self
            submenu.addItem(grantItem)
        case .denied, .restricted:
            submenu.addItem(disabledMenuItem(localized("smartPauseCalendarPermissionDenied")))
            let settingsItem = NSMenuItem(
                title: localized("smartPauseCalendarOpenSettings"),
                action: #selector(openCalendarSettings),
                keyEquivalent: ""
            )
            settingsItem.target = self
            submenu.addItem(settingsItem)
        case .authorized:
            break
        }

        if calendarBreakSettings.isEnabled && snapshot.permissionState == .authorized {
            if calendarBreakSettings.selectedCalendarID == nil {
                submenu.addItem(disabledMenuItem(localized("calendarBreaksNoCalendarSelected")))
            } else if calendarBreakPolicy.isSelectedCalendarMissing(settings: calendarBreakSettings, snapshot: snapshot) {
                let name = calendarBreakSettings.selectedCalendarTitle
                    ?? calendarBreakSettings.selectedCalendarID
                    ?? ""
                submenu.addItem(disabledMenuItem(String(format: localized("calendarBreaksMissingCalendarFormat"), name)))
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let selectCalendarItem = NSMenuItem(title: localized("calendarBreaksSelectCalendar"), action: nil, keyEquivalent: "")
        let calendarSubmenu = NSMenu()
        if snapshot.permissionState != .authorized {
            calendarSubmenu.addItem(disabledMenuItem(localized("smartPauseCalendarAccessRequired")))
        } else if snapshot.availableCalendars.isEmpty {
            calendarSubmenu.addItem(disabledMenuItem(localized("smartPauseCalendarNoCalendars")))
        } else {
            let noneItem = NSMenuItem(
                title: localized("calendarBreaksNoneOption"),
                action: #selector(clearCalendarBreakSelection),
                keyEquivalent: ""
            )
            noneItem.target = self
            noneItem.state = (calendarBreakSettings.selectedCalendarID == nil) ? .on : .off
            calendarSubmenu.addItem(noneItem)
            calendarSubmenu.addItem(NSMenuItem.separator())

            for calendar in snapshot.availableCalendars {
                let title = calendar.sourceTitle.isEmpty
                    ? calendar.title
                    : "\(calendar.title) (\(calendar.sourceTitle))"
                let item = NSMenuItem(
                    title: title,
                    action: #selector(selectCalendarForBreaks(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = calendar.id
                item.state = (calendarBreakSettings.selectedCalendarID == calendar.id) ? .on : .off
                calendarSubmenu.addItem(item)
            }

            if let selectedID = calendarBreakSettings.selectedCalendarID,
               !snapshot.availableCalendars.contains(where: { $0.id == selectedID }) {
                calendarSubmenu.addItem(NSMenuItem.separator())
                let missingName = calendarBreakSettings.selectedCalendarTitle ?? selectedID
                let missingItem = NSMenuItem(
                    title: String(format: localized("calendarBreaksMissingOptionFormat"), missingName),
                    action: nil,
                    keyEquivalent: ""
                )
                missingItem.isEnabled = false
                missingItem.state = .on
                calendarSubmenu.addItem(missingItem)
            }
        }
        selectCalendarItem.submenu = calendarSubmenu
        submenu.addItem(selectCalendarItem)

        let filterText = calendarBreakSettings.trimmedTitleFilter
        let filterTitle = filterText.isEmpty
            ? localized("calendarBreaksTitleFilterAll")
            : String(format: localized("calendarBreaksTitleFilterFormat"), filterText)
        let filterItem = NSMenuItem(
            title: filterTitle,
            action: #selector(promptCalendarBreakTitleFilter),
            keyEquivalent: ""
        )
        filterItem.target = self
        submenu.addItem(filterItem)

        if !filterText.isEmpty {
            let clearFilterItem = NSMenuItem(
                title: localized("calendarBreaksClearFilter"),
                action: #selector(clearCalendarBreakTitleFilter),
                keyEquivalent: ""
            )
            clearFilterItem.target = self
            submenu.addItem(clearFilterItem)
        }

        return submenu
    }

    @objc private func toggleCalendarBreaks() {
        let nextEnabled = !calendarBreakSettings.isEnabled
        calendarBreakSettings.isEnabled = nextEnabled
        saveSettings()
        syncCalendarEventMonitorState()

        if nextEnabled && calendarEventMonitor.currentSnapshot().permissionState == .notDetermined {
            calendarEventMonitor.requestAccess { [weak self] _ in
                self?.rebuildCalendarBreaksMenu()
                self?.evaluateSmartPause(refreshSnapshots: true)
                self?.rescheduleCountdown()
            }
            return
        }

        rebuildCalendarBreaksMenu()
        evaluateSmartPause(refreshSnapshots: true)
        rescheduleCountdown()
    }

    @objc private func clearCalendarBreakSelection() {
        calendarBreakSettings.selectedCalendarID = nil
        calendarBreakSettings.selectedCalendarTitle = nil
        saveSettings()
        rebuildCalendarBreaksMenu()
        evaluateSmartPause(refreshSnapshots: true)
        rescheduleCountdown()
    }

    @objc private func selectCalendarForBreaks(_ sender: NSMenuItem) {
        guard let calendarID = sender.representedObject as? String else { return }
        let snapshot = calendarEventMonitor.currentSnapshot()
        calendarBreakSettings.selectedCalendarID = calendarID
        calendarBreakSettings.selectedCalendarTitle = snapshot.availableCalendars.first(where: { $0.id == calendarID })?.title
        saveSettings()
        rebuildCalendarBreaksMenu()
        evaluateSmartPause(refreshSnapshots: true)
        rescheduleCountdown()
    }

    @objc private func promptCalendarBreakTitleFilter() {
        let alert = NSAlert()
        alert.messageText = localized("calendarBreaksFilterPromptTitle")
        alert.informativeText = localized("calendarBreaksFilterPromptMessage")
        alert.addButton(withTitle: localized("calendarBreaksSave"))
        alert.addButton(withTitle: localized("calendarBreaksClearFilter"))
        alert.addButton(withTitle: localized("nightOverrideCancel"))

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        inputField.placeholderString = localized("calendarBreaksFilterPlaceholder")
        inputField.stringValue = calendarBreakSettings.titleFilter
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            calendarBreakSettings.titleFilter = inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if response == .alertSecondButtonReturn {
            calendarBreakSettings.titleFilter = ""
        } else {
            return
        }

        saveSettings()
        rebuildCalendarBreaksMenu()
        evaluateSmartPause(refreshSnapshots: true)
        rescheduleCountdown()
    }

    @objc private func clearCalendarBreakTitleFilter() {
        calendarBreakSettings.titleFilter = ""
        saveSettings()
        rebuildCalendarBreaksMenu()
        evaluateSmartPause(refreshSnapshots: true)
        rescheduleCountdown()
    }
}

// MARK: - On-Demand Manual Breaks

extension AppDelegate {
    private func setupManualBreakMenu() {
        manualBreakMenuItem = NSMenuItem(title: localized("manualBreakMenuTitle"), action: nil, keyEquivalent: "")
        manualBreakMenuItem.submenu = buildManualBreakSubmenu()
        menu.addItem(manualBreakMenuItem)
    }

    private func rebuildManualBreakMenu() {
        guard manualBreakMenuItem != nil else { return }
        manualBreakMenuItem.title = localized("manualBreakMenuTitle")
        manualBreakMenuItem.submenu = buildManualBreakSubmenu()
    }

    private func buildManualBreakSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let nightLocked = currentNightStatus().isLocked

        for minutes in ManualBreakPreset.quickDurationMinutes {
            let item = NSMenuItem(
                title: String(format: localized("manualBreakQuickDurationFormat"), minutes),
                action: #selector(startQuickManualBreak(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = minutes * 60
            item.isEnabled = !nightLocked
            submenu.addItem(item)
        }

        let customItem = NSMenuItem(
            title: localized("manualBreakCustomDurationMenu"),
            action: #selector(openCustomManualBreakDialog),
            keyEquivalent: "b"
        )
        customItem.target = self
        customItem.keyEquivalentModifierMask = .command
        customItem.isEnabled = !nightLocked
        submenu.addItem(customItem)

        submenu.addItem(NSMenuItem.separator())
        submenu.addItem(disabledMenuItem(localized("manualBreakPresetsHeader")))

        if manualBreakSettings.presets.isEmpty {
            submenu.addItem(disabledMenuItem(localized("manualBreakNoPresets")))
        } else {
            for preset in manualBreakSettings.presets {
                let displayName = preset.name.isEmpty ? localized("manualBreakDefaultTitle") : preset.name
                let title = String(format: localized("manualBreakPresetMenuItemFormat"), displayName, preset.formattedDuration)
                let item = NSMenuItem(
                    title: title,
                    action: #selector(startManualBreakPreset(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = preset.id.uuidString
                item.isEnabled = !nightLocked

                let presetSubmenu = NSMenu()
                let startNowItem = NSMenuItem(
                    title: localized("manualBreakPresetStart"),
                    action: #selector(startManualBreakPreset(_:)),
                    keyEquivalent: ""
                )
                startNowItem.target = self
                startNowItem.representedObject = preset.id.uuidString
                startNowItem.isEnabled = !nightLocked
                presetSubmenu.addItem(startNowItem)

                let editItem = NSMenuItem(
                    title: localized("manualBreakPresetEdit"),
                    action: #selector(editManualBreakPreset(_:)),
                    keyEquivalent: ""
                )
                editItem.target = self
                editItem.representedObject = preset.id.uuidString
                presetSubmenu.addItem(editItem)

                let deleteItem = NSMenuItem(
                    title: localized("manualBreakPresetDelete"),
                    action: #selector(deleteManualBreakPreset(_:)),
                    keyEquivalent: ""
                )
                deleteItem.target = self
                deleteItem.representedObject = preset.id.uuidString
                presetSubmenu.addItem(deleteItem)

                item.submenu = presetSubmenu
                submenu.addItem(item)
            }
        }

        let addPresetItem = NSMenuItem(
            title: localized("manualBreakAddPreset"),
            action: #selector(addManualBreakPreset),
            keyEquivalent: ""
        )
        addPresetItem.target = self
        submenu.addItem(addPresetItem)

        submenu.addItem(NSMenuItem.separator())

        let manualOnlyItem = NSMenuItem(
            title: localized("manualBreakManualOnlyMode"),
            action: #selector(toggleManualOnlyMode),
            keyEquivalent: ""
        )
        manualOnlyItem.target = self
        manualOnlyItem.state = manualBreakSettings.isManualOnlyMode ? .on : .off
        submenu.addItem(manualOnlyItem)

        return submenu
    }

    @objc private func startQuickManualBreak(_ sender: NSMenuItem) {
        let seconds = manualBreakPolicy.validatedDurationSeconds(sender.tag)
        startManualBreak(
            title: localized("manualBreakDefaultTitle"),
            durationSeconds: seconds,
            presetID: nil
        )
    }

    @objc private func openCustomManualBreakDialog() {
        guard !currentNightStatus().isLocked else {
            _ = applyNightRestrictionState(reason: "manual_break_blocked")
            return
        }

        let alert = NSAlert()
        alert.messageText = localized("manualBreakCustomTitle")
        alert.informativeText = localized("manualBreakCustomMessage")
        alert.addButton(withTitle: localized("manualBreakStartButton"))
        alert.addButton(withTitle: localized("manualBreakCancelButton"))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))

        let minutesLabel = NSTextField(labelWithString: localized("manualBreakDurationMinutesLabel"))
        minutesLabel.frame = NSRect(x: 0, y: 126, width: 200, height: 18)
        container.addSubview(minutesLabel)

        let minutesField = NSTextField(frame: NSRect(x: 0, y: 98, width: 140, height: 24))
        minutesField.integerValue = 5
        container.addSubview(minutesField)

        let secondsLabel = NSTextField(labelWithString: localized("manualBreakDurationSecondsLabel"))
        secondsLabel.frame = NSRect(x: 160, y: 126, width: 160, height: 18)
        container.addSubview(secondsLabel)

        let secondsField = NSTextField(frame: NSRect(x: 160, y: 98, width: 140, height: 24))
        secondsField.integerValue = 0
        container.addSubview(secondsField)

        let savePresetCheckbox = NSButton(checkboxWithTitle: localized("manualBreakSaveAsPresetCheckbox"), target: nil, action: nil)
        savePresetCheckbox.frame = NSRect(x: 0, y: 66, width: 320, height: 20)
        savePresetCheckbox.state = .off
        container.addSubview(savePresetCheckbox)

        let nameLabel = NSTextField(labelWithString: localized("manualBreakPresetNameLabel"))
        nameLabel.frame = NSRect(x: 0, y: 38, width: 320, height: 18)
        container.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 0, y: 8, width: 320, height: 24))
        nameField.placeholderString = localized("manualBreakPresetNamePlaceholder")
        container.addSubview(nameField)

        alert.accessoryView = container
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let mins = max(0, minutesField.integerValue)
        let secs = max(0, min(59, secondsField.integerValue))
        let totalSeconds = manualBreakPolicy.validatedDurationSeconds(minutes: mins, seconds: secs)
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmedName.isEmpty ? localized("manualBreakDefaultTitle") : trimmedName

        var savedPresetID: UUID?
        if savePresetCheckbox.state == .on {
            let preset = ManualBreakPreset(name: title, durationSeconds: totalSeconds)
            manualBreakSettings.add(preset)
            savedPresetID = preset.id
            saveSettings()
            rebuildManualBreakMenu()
        }

        startManualBreak(
            title: title,
            durationSeconds: totalSeconds,
            presetID: savedPresetID
        )
    }

    @objc private func startManualBreakPreset(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID),
              let preset = manualBreakSettings.presets.first(where: { $0.id == id }) else {
            return
        }
        let title = preset.name.isEmpty ? localized("manualBreakDefaultTitle") : preset.name
        startManualBreak(
            title: title,
            durationSeconds: preset.durationSeconds,
            presetID: preset.id,
            completionBehaviorOverride: preset.completionBehavior
        )
    }

    @objc private func addManualBreakPreset() {
        promptManualBreakPresetEditor(existing: nil)
    }

    @objc private func editManualBreakPreset(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID),
              let existing = manualBreakSettings.presets.first(where: { $0.id == id }) else {
            return
        }
        promptManualBreakPresetEditor(existing: existing)
    }

    @objc private func deleteManualBreakPreset(_ sender: NSMenuItem) {
        guard let rawID = sender.representedObject as? String,
              let id = UUID(uuidString: rawID) else {
            return
        }
        manualBreakSettings.remove(id: id)
        saveSettings()
        rebuildManualBreakMenu()
    }

    private func promptManualBreakPresetEditor(existing: ManualBreakPreset?) {
        let alert = NSAlert()
        alert.messageText = existing == nil ? localized("manualBreakPresetCreateTitle") : localized("manualBreakPresetEditTitle")
        alert.addButton(withTitle: localized("manualBreakSaveButton"))
        alert.addButton(withTitle: localized("manualBreakCancelButton"))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 118))

        let nameLabel = NSTextField(labelWithString: localized("manualBreakPresetNameLabel"))
        nameLabel.frame = NSRect(x: 0, y: 94, width: 320, height: 18)
        container.addSubview(nameLabel)

        let nameField = NSTextField(frame: NSRect(x: 0, y: 66, width: 320, height: 24))
        nameField.placeholderString = localized("manualBreakPresetNamePlaceholder")
        nameField.stringValue = existing?.name ?? ""
        container.addSubview(nameField)

        let minutesLabel = NSTextField(labelWithString: localized("manualBreakDurationMinutesLabel"))
        minutesLabel.frame = NSRect(x: 0, y: 38, width: 150, height: 18)
        container.addSubview(minutesLabel)

        let minutesField = NSTextField(frame: NSRect(x: 0, y: 10, width: 140, height: 24))
        minutesField.integerValue = (existing?.durationSeconds ?? 300) / 60
        container.addSubview(minutesField)

        let secondsLabel = NSTextField(labelWithString: localized("manualBreakDurationSecondsLabel"))
        secondsLabel.frame = NSRect(x: 160, y: 38, width: 160, height: 18)
        container.addSubview(secondsLabel)

        let secondsField = NSTextField(frame: NSRect(x: 160, y: 10, width: 140, height: 24))
        secondsField.integerValue = (existing?.durationSeconds ?? 300) % 60
        container.addSubview(secondsField)

        alert.accessoryView = container
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? localized("manualBreakDefaultTitle") : trimmedName
        let mins = max(0, minutesField.integerValue)
        let secs = max(0, min(59, secondsField.integerValue))
        let totalSeconds = manualBreakPolicy.validatedDurationSeconds(minutes: mins, seconds: secs)

        let preset = ManualBreakPreset(
            id: existing?.id ?? UUID(),
            name: finalName,
            durationSeconds: totalSeconds,
            completionBehavior: existing?.completionBehavior
        )

        if existing != nil {
            manualBreakSettings.update(preset)
        } else {
            manualBreakSettings.add(preset)
        }
        saveSettings()
        rebuildManualBreakMenu()
    }

    @objc private func toggleManualOnlyMode() {
        manualBreakSettings.isManualOnlyMode.toggle()
        saveSettings()

        if manualBreakSettings.isManualOnlyMode {
            if breakSessionStartTime == nil {
                enterManualOnlyIdleState()
            } else {
                updateStatusBarTitle()
                updateMenuTimer()
            }
        } else {
            if breakSessionStartTime == nil && !currentNightStatus().isLocked {
                restartWorkTimer()
            } else {
                updateStatusBarTitle()
                updateMenuTimer()
            }
        }

        rebuildManualBreakMenu()
    }

    private func startManualBreak(
        title: String,
        durationSeconds: Int,
        presetID: UUID?,
        completionBehaviorOverride: ManualBreakCompletionBehavior? = nil
    ) {
        let now = Date()
        let nightStatus = currentNightStatus(now: now)
        let capturedRemaining: TimeInterval?
        if workSessionStartTime != nil && !isPostponeActive && !manualBreakSettings.isManualOnlyMode {
            capturedRemaining = remainingWorkTime(at: now, status: nightStatus)
        } else {
            capturedRemaining = nil
        }

        guard let manualBreak = manualBreakPolicy.startManualBreak(
            title: title,
            durationSeconds: durationSeconds,
            presetID: presetID,
            now: now,
            currentWorkRemaining: capturedRemaining,
            isManualOnlyMode: manualBreakSettings.isManualOnlyMode,
            isNightLocked: nightStatus.isLocked,
            completionBehaviorOverride: completionBehaviorOverride
        ) else {
            _ = applyNightRestrictionState(reason: "manual_break_blocked")
            return
        }

        if let startTime = workSessionStartTime {
            let elapsed = now.timeIntervalSince(startTime)
            logManager.logWorkPaused(duration: elapsed, reason: "manual_break")
            eventRecorder.endWorkSession()
        }

        countdownScheduler.cancel()
        cancelInputDeferral()
        dismissPreBreakHUD()
        postponeStartTime = nil
        postponeDuration = 0
        totalPostponedTime = 0
        activePlannedBreakOccurrence = nil
        activeCalendarBreakOccurrence = nil

        activeManualBreak = manualBreak
        activeBreakDurationOverrideSeconds = manualBreak.durationSeconds
        showBreakOverlay(bypassInputDeferral: true)
    }

    private func enterManualOnlyIdleState() {
        cancelInputDeferral()
        dismissPreBreakHUD()
        countdownScheduler.cancel()
        workSessionStartTime = nil
        breakSessionStartTime = nil
        postponeStartTime = nil
        postponeDuration = 0
        totalPostponedTime = 0
        isPausedBySystemEvent = false
        updateStatusBarTitle()
        updateMenuTimer()
        saveCurrentSessionState()
        rescheduleCountdown()
    }

    private func applyManualBreakPostAction(_ action: ManualBreakPostAction) {
        switch action {
        case .idleManualOnly:
            enterManualOnlyIdleState()
        case .resetWorkCycle:
            startWorkTimer(forceFreshSession: true)
        case .restoreWorkCycle(let remainingSeconds):
            cancelInputDeferral()
            let now = Date()
            let fullDuration = TimeInterval(effectiveWorkDuration)
            let clampedRemaining = min(fullDuration, max(1, remainingSeconds))
            workSessionStartTime = now.addingTimeInterval(-(fullDuration - clampedRemaining))
            breakSessionStartTime = nil
            postponeStartTime = nil
            postponeDuration = 0
            totalPostponedTime = 0
            isPausedBySystemEvent = false

            logSessionDebug("manual_break_restored_work_session", context: [
                "remaining_seconds": "\(Int(clampedRemaining))"
            ])
            eventRecorder.startWorkSession(duration: effectiveWorkDuration)
            updateStatusBarTitle()
            updateMenuTimer()
            saveCurrentSessionState()
            rescheduleCountdown()
        }
    }
}
