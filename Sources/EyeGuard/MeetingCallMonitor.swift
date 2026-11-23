import Cocoa
import CoreAudio
import EyeGuardCore

/// Monitors macOS audio input devices via CoreAudio HAL (without triggering microphone TCC prompts)
/// and collects running/frontmost application metadata for Smart Pause evaluation.
final class MeetingCallMonitor {
    struct Snapshot: Equatable {
        let isAudioInputActive: Bool
        let runningApps: [RunningAppInfo]
    }

    var onUpdate: ((Snapshot) -> Void)?

    private let pollInterval: TimeInterval
    private var pollTimer: Timer?
    private(set) var lastSnapshot = Snapshot(isAudioInputActive: false, runningApps: [])

    init(pollInterval: TimeInterval = 2.0) {
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

    func pollNow() {
        let snapshot = currentSnapshot()
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    func currentSnapshot() -> Snapshot {
        Snapshot(
            isAudioInputActive: Self.isAnyAudioInputDeviceRunning(),
            runningApps: Self.collectRunningApps()
        )
    }

    static func collectRunningApps() -> [RunningAppInfo] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy != .prohibited else { return nil }
            let bundleID = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            guard !bundleID.isEmpty || !name.isEmpty else { return nil }
            return RunningAppInfo(
                bundleIdentifier: bundleID,
                localizedName: name,
                isFrontmost: app.processIdentifier == frontmostPID
            )
        }
    }

    /// Queries CoreAudio HAL `kAudioDevicePropertyDeviceIsRunningSomewhere` on input devices.
    /// This inspects hardware/driver state only and does not open audio streams or trigger mic permissions.
    static func isAnyAudioInputDeviceRunning() -> Bool {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObjectID, &devicesAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return false
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        let status = deviceIDs.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(systemObjectID, &devicesAddress, 0, nil, &dataSize, baseAddress)
        }
        guard status == noErr else { return false }

        for deviceID in deviceIDs where deviceHasInputStreams(deviceID) {
            if isAudioDeviceRunningSomewhere(deviceID) {
                return true
            }
        }
        return false
    }

    private static func deviceHasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &dataSize, rawPointer) == noErr else {
            return false
        }

        let bufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channelCount > 0
    }

    private static func isAudioDeviceRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &dataSize, &isRunning) == noErr else {
            return false
        }
        return isRunning != 0
    }
}
