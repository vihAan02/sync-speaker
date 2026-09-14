import CoreAudio
import Foundation
import Synchronization

/// Records a mono window from the default input device, starting at a given local host time.
/// Used for acoustic calibration, so only relative timing inside the recording matters.
public final class MicRecorder: @unchecked Sendable {
    public struct Recording: Sendable {
        public var samples: [Float]
        public var sampleRate: Double
        /// Local host time of `samples[0]`.
        public var startHostNs: Int64
    }

    public init() {}

    public func record(startHostNs: Int64, seconds: Double) async throws -> Recording {
        let device = try CoreAudioDevices.defaultInputDevice()
        guard device != kAudioObjectUnknown else { throw AudioIOError("No input device") }
        let rate = try CoreAudioDevices.nominalSampleRate(of: device)
        let capacity = Int(seconds * rate)
        let state = RecordState(capacity: capacity)

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, input, inputTime, _, _ in
            MicRecorder.ioBlock(input: input, time: inputTime, state: state, startHostNs: startHostNs, rate: rate)
        }, "AudioDeviceCreateIOProcIDWithBlock(input)")
        guard let proc = procID else { throw AudioIOError("No IOProc for input device") }
        defer { AudioDeviceDestroyIOProcID(device, proc) }
        try check(AudioDeviceStart(device, proc), "AudioDeviceStart(input)")
        defer { AudioDeviceStop(device, proc) }

        let deadline = startHostNs + Int64((seconds + 2) * 1e9)
        while state.count.load(ordering: .relaxed) < capacity {
            if Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) > deadline {
                throw AudioIOError("Microphone recording timed out (is microphone access granted?)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return Recording(samples: Array(UnsafeBufferPointer(start: state.buffer, count: capacity)),
                         sampleRate: rate, startHostNs: state.firstHostNs.load(ordering: .relaxed))
    }

    final class RecordState: @unchecked Sendable {
        let buffer: UnsafeMutablePointer<Float>
        let capacity: Int
        let count = Atomic<Int>(0)
        let firstHostNs = Atomic<Int64>(0)

        init(capacity: Int) {
            self.capacity = capacity
            buffer = .allocate(capacity: capacity)
            buffer.initialize(repeating: 0, count: capacity)
        }

        deinit { buffer.deallocate() }
    }

    private static func ioBlock(input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>,
                                state: RecordState, startHostNs: Int64, rate: Double) {
        guard let hostNs = time.pointee.hostNs else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let data = first.mData, first.mNumberChannels > 0 else { return }
        let ch = Int(first.mNumberChannels)
        let frames = Int(first.mDataByteSize) / (4 * ch)
        let src = data.assumingMemoryBound(to: Float.self)
        let nsPerFrame = 1e9 / rate
        var count = state.count.load(ordering: .relaxed)
        for f in 0..<frames where count < state.capacity {
            let frameNs = hostNs + Int64(Double(f) * nsPerFrame)
            if frameNs < startHostNs { continue }
            if count == 0 { state.firstHostNs.store(frameNs, ordering: .relaxed) }
            state.buffer[count] = src[f * ch] // first channel of the first buffer
            count += 1
        }
        state.count.store(count, ordering: .relaxed)
    }
}
