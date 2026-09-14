import CDSP
import CoreAudio
import Foundation

/// Drives an `ss_playout` renderer from the default output device's IOProc.
/// Every channel of the device receives the node's mono feed.
public final class OutputRenderer: @unchecked Sendable {
    public private(set) var deviceID = AudioDeviceID(0)
    public private(set) var deviceName = ""
    public private(set) var sampleRate: Double = 0
    public private(set) var reportedLatency: Double = 0

    private let playout: OpaquePointer
    private let maxFrames = 8192
    private let scratch: UnsafeMutablePointer<Float>
    private var procID: AudioDeviceIOProcID?

    /// - Parameter playout: an `ss_playout*` that outlives this renderer.
    public init(playout: OpaquePointer) {
        self.playout = playout
        scratch = .allocate(capacity: maxFrames)
        scratch.initialize(repeating: 0, count: maxFrames)
    }

    deinit {
        stop()
        scratch.deallocate()
    }

    public var isRunning: Bool { procID != nil }

    /// Starts on the current default output device. Returns its reported output latency in seconds.
    @discardableResult
    public func start() throws -> Double {
        guard procID == nil else { return reportedLatency }
        let device = try CoreAudioDevices.defaultOutputDevice()
        let rate = try CoreAudioDevices.nominalSampleRate(of: device)
        guard rate > 0 else { throw AudioIOError("Output device has no sample rate") }
        deviceID = device
        deviceName = CoreAudioDevices.name(of: device)
        sampleRate = rate
        reportedLatency = CoreAudioDevices.outputLatency(of: device)

        let playout = self.playout
        let scratch = self.scratch
        let maxFrames = self.maxFrames
        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, _, _, output, outputTime in
            OutputRenderer.ioBlock(output: output, time: outputTime, playout: playout, scratch: scratch,
                                   maxFrames: maxFrames, sampleRate: rate)
        }, "AudioDeviceCreateIOProcIDWithBlock(output)")
        procID = proc
        do {
            try check(AudioDeviceStart(device, proc), "AudioDeviceStart(output)")
        } catch {
            stop()
            throw error
        }
        return reportedLatency
    }

    public func stop() {
        guard let procID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
    }

    /// True when the default output device or its sample rate changed since `start()`.
    public func deviceChanged() -> Bool {
        guard isRunning, let current = try? CoreAudioDevices.defaultOutputDevice() else { return false }
        return current != deviceID || (try? CoreAudioDevices.nominalSampleRate(of: current)) != sampleRate
    }

    private static func ioBlock(output: UnsafeMutablePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>,
                                playout: OpaquePointer, scratch: UnsafeMutablePointer<Float>, maxFrames: Int,
                                sampleRate: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(output)
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frames = min(Int(first.mDataByteSize) / (4 * Int(first.mNumberChannels)), maxFrames)
        guard let hostNs = time.pointee.hostNs else {
            for b in buffers { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        ss_playout_render(playout, hostNs, scratch, Int32(frames), sampleRate)
        for b in buffers {
            guard let data = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = Int(b.mNumberChannels)
            for f in 0..<frames {
                let v = scratch[f]
                for c in 0..<ch { data[f * ch + c] = v }
            }
        }
    }
}
