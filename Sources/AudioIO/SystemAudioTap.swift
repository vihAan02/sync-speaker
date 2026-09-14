import CDSP
import CoreAudio
import Foundation

/// Captures everything the Mac plays (AirPlay Receiver, Music.app, …) except this process, and mutes
/// it at the hardware so the only audible output is our synchronized playout.
///
/// Requires macOS 14.4+, `NSAudioCaptureUsageDescription`, and the user's "System Audio Recording" grant.
public final class SystemAudioTap: @unchecked Sendable {
    public let channels = 2
    public private(set) var sampleRate: Double = 0
    public var droppedBlocks: Int64 { ss_block_fifo_dropped(fifo) }

    /// Filled on the IO thread; drain with `pop`.
    private let fifo: OpaquePointer
    private let maxFrames = 4096
    private let scratch: UnsafeMutablePointer<Float>

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    public init() {
        fifo = ss_block_fifo_create(2, Int32(maxFrames), 512)
        scratch = .allocate(capacity: maxFrames * 2)
        scratch.initialize(repeating: 0, count: maxFrames * 2)
    }

    deinit {
        stop()
        ss_block_fifo_destroy(fifo)
        scratch.deallocate()
    }

    public var isRunning: Bool { procID != nil }

    /// - Parameter mute: silence tapped processes on the hardware (speaker mode).
    public func start(mute: Bool = true) throws {
        guard procID == nil else { return }
        // Exclude ourselves so our own playout is never re-captured.
        let excluded = CoreAudioDevices.processObject(pid: getpid()).map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "SyncSpeaker Capture"
        description.isPrivate = true
        description.muteBehavior = mute ? .muted : .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        do {
            let format = try CoreAudioDevices.get(tap, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw AudioIOError("Unsupported tap format: \(format)")
            }
            sampleRate = format.mSampleRate

            let outputUID = try CoreAudioDevices.uid(of: CoreAudioDevices.defaultOutputDevice())
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "SyncSpeaker Tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var aggregateDevice = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateDevice),
                      "AudioHardwareCreateAggregateDevice")
            aggregateID = aggregateDevice

            let fifo = self.fifo
            let scratch = self.scratch
            let maxFrames = self.maxFrames
            var proc: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateDevice, nil) { _, input, inputTime, _, _ in
                SystemAudioTap.ioBlock(input: input, time: inputTime, fifo: fifo, scratch: scratch, maxFrames: maxFrames)
            }, "AudioDeviceCreateIOProcIDWithBlock")
            procID = proc
            try check(AudioDeviceStart(aggregateDevice, proc), "AudioDeviceStart(tap)")
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Consumer side: copies the next captured block (interleaved stereo) into `buffer`.
    /// Returns (frames, host time of the first frame in ns) or nil when empty.
    public func pop(into buffer: UnsafeMutablePointer<Float>, capacityFrames: Int) -> (frames: Int, hostNs: Int64)? {
        var host: Int64 = 0
        let n = ss_block_fifo_pop(fifo, &host, buffer, Int32(capacityFrames))
        return n < 0 ? nil : (Int(n), host)
    }

    public var maxBlockFrames: Int { maxFrames }

    // Runs on the HAL IO thread: no allocation, no locks, no Swift object access.
    private static func ioBlock(input: UnsafePointer<AudioBufferList>, time: UnsafePointer<AudioTimeStamp>,
                                fifo: OpaquePointer, scratch: UnsafeMutablePointer<Float>, maxFrames: Int) {
        guard let hostNs = time.pointee.hostNs else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0, let firstData = first.mData else { return }

        if buffers.count == 1 {
            let ch = Int(first.mNumberChannels)
            let frames = min(Int(first.mDataByteSize) / (4 * ch), maxFrames)
            let src = firstData.assumingMemoryBound(to: Float.self)
            if ch == 2 {
                ss_block_fifo_push(fifo, hostNs, src, Int32(frames))
            } else {
                for f in 0..<frames {
                    scratch[f * 2] = src[f * ch]
                    scratch[f * 2 + 1] = src[f * ch + min(1, ch - 1)]
                }
                ss_block_fifo_push(fifo, hostNs, scratch, Int32(frames))
            }
        } else {
            // Non-interleaved: one buffer per channel.
            let frames = min(Int(first.mDataByteSize) / 4, maxFrames)
            let left = firstData.assumingMemoryBound(to: Float.self)
            let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left
            for f in 0..<frames {
                scratch[f * 2] = left[f]
                scratch[f * 2 + 1] = right[f]
            }
            ss_block_fifo_push(fifo, hostNs, scratch, Int32(frames))
        }
    }
}
