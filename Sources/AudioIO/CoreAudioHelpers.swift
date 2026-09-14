import CoreAudio
import Foundation

public struct AudioIOError: Error, CustomStringConvertible {
    public let description: String

    init(_ what: String, _ status: OSStatus) {
        let code = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        let fourCC = bytes.allSatisfy { (32...126).contains($0) } ? " '\(String(decoding: bytes, as: UTF8.self))'" : ""
        description = "\(what) failed: OSStatus \(status)\(fourCC)"
    }

    init(_ message: String) {
        description = message
    }
}

@inline(__always)
func check(_ status: OSStatus, _ what: @autoclosure () -> String) throws {
    if status != noErr { throw AudioIOError(what(), status) }
}

public enum CoreAudioDevices {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var addr = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value), "get property \(selector)")
        return value
    }

    public static func defaultOutputDevice() throws -> AudioDeviceID {
        try get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
    }

    public static func defaultInputDevice() throws -> AudioDeviceID {
        try get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0))
    }

    static func getString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) },
                  "get string property \(selector)")
        // Core Audio returns CF objects retained for the caller.
        return value?.takeRetainedValue() as String? ?? ""
    }

    public static func uid(of device: AudioDeviceID) throws -> String {
        try getString(device, kAudioDevicePropertyDeviceUID)
    }

    public static func name(of device: AudioDeviceID) -> String {
        (try? getString(device, kAudioObjectPropertyName)) ?? "Unknown"
    }

    public static func nominalSampleRate(of device: AudioDeviceID) throws -> Double {
        try get(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    /// Seconds from the IOProc output timestamp until sound leaves the device.
    public static func outputLatency(of device: AudioDeviceID) -> Double {
        let rate = (try? nominalSampleRate(of: device)) ?? 48_000
        let scope = kAudioObjectPropertyScopeOutput
        let deviceLatency = (try? get(device, kAudioDevicePropertyLatency, scope: scope, initial: UInt32(0))) ?? 0
        let safety = (try? get(device, kAudioDevicePropertySafetyOffset, scope: scope, initial: UInt32(0))) ?? 0
        var streamLatency: UInt32 = 0
        if let stream = firstStream(of: device, scope: scope) {
            streamLatency = (try? get(stream, kAudioStreamPropertyLatency, initial: UInt32(0))) ?? 0
        }
        return Double(deviceLatency + safety + streamLatency) / rate
    }

    static func firstStream(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> AudioStreamID? {
        var addr = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    /// The HAL process object for a PID (exists once the process has touched Core Audio).
    public static func processObject(pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}

extension AudioTimeStamp {
    /// Host time in nanoseconds, if the timestamp carries one.
    var hostNs: Int64? {
        guard mFlags.contains(.hostTimeValid) else { return nil }
        return Int64(AudioConvertHostTimeToNanos(mHostTime))
    }
}
