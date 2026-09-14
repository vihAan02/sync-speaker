import CDSP
import Foundation
import SyncProtocol

/// Swift owner of the C timeline + playout renderer.
///
/// Threading: `ingest` from one writer thread, `render` from the audio IO thread, everything else from anywhere.
public final class PlayoutEngine: @unchecked Sendable {
    public let channels: Int
    private let timeline: OpaquePointer
    private let renderer: OpaquePointer
    private let overlayCapacity: Int

    private let lock = NSLock()
    private var epoch: UInt32?
    private var scratch = [Float]()
    private var outputLatencySeconds = 0.0
    private var trimSeconds = 0.0

    public init(channels: Int = 2, capacityFrames: Int = 1 << 18, maxFramesPerRender: Int = 8192,
                overlayCapacityFrames: Int = 96_000 * 2) {
        self.channels = channels
        overlayCapacity = overlayCapacityFrames
        timeline = ss_timeline_create(Int32(channels), Int64(capacityFrames))
        renderer = ss_playout_create(timeline, Int32(maxFramesPerRender), Int32(overlayCapacityFrames))
    }

    deinit {
        ss_playout_destroy(renderer)
        ss_timeline_destroy(timeline)
    }

    // MARK: Writer

    /// Stores decoded interleaved samples. Resets the timeline when the stream epoch changes.
    public func ingest(header: AudioChunkHeader, samples: UnsafeBufferPointer<Float>) {
        let inChannels = Int(header.channels)
        guard inChannels > 0 else { return }
        let frames = samples.count / inChannels
        if epoch != header.epoch {
            epoch = header.epoch
            ss_timeline_reset(timeline)
        }
        if inChannels == channels {
            ss_timeline_write(timeline, header.frameIndex, samples.baseAddress, Int32(frames), header.ptsNs, header.nsPerFrame)
            return
        }
        // Up/down-mix to the timeline's channel count.
        if scratch.count < frames * channels { scratch = [Float](repeating: 0, count: frames * channels) }
        for f in 0..<frames {
            for c in 0..<channels {
                scratch[f * channels + c] = samples[f * inChannels + min(c, inChannels - 1)]
            }
        }
        scratch.withUnsafeBufferPointer {
            ss_timeline_write(timeline, header.frameIndex, $0.baseAddress, Int32(frames), header.ptsNs, header.nsPerFrame)
        }
    }

    private var decodeBuffer = [Float]()

    /// Decodes an audio link frame payload (header + samples) and ingests it.
    public func ingest(chunk: Data) throws {
        let header = try AudioChunkCodec.decodeHeader(chunk)
        let frames = try AudioChunkCodec.decodeSamples(chunk, header: header, into: &decodeBuffer)
        decodeBuffer.withUnsafeBufferPointer {
            ingest(header: header, samples: UnsafeBufferPointer(rebasing: $0[0..<(frames * Int(header.channels))]))
        }
    }

    // MARK: Control

    public func setClockMap(localRefNs: Int64, clusterRefNs: Int64, rate: Double) {
        ss_playout_set_clock_map(renderer, localRefNs, clusterRefNs, rate)
    }

    public func setOutputLatency(seconds: Double) {
        lock.withLock { outputLatencySeconds = seconds }
        ss_playout_set_output_latency_ns(renderer, Int64(seconds * 1e9))
    }

    /// Extra real-world latency of this node beyond what the device reports (from acoustic calibration).
    public var trim: Double {
        get { lock.withLock { trimSeconds } }
        set {
            lock.withLock { trimSeconds = newValue }
            ss_playout_set_trim_ns(renderer, Int64(newValue * 1e9))
        }
    }

    public func setRender(_ render: SpeakerRender) {
        let mix = render.mix
        ss_playout_set_render(renderer, render.delaySeconds, Float(render.gain), mix.left, mix.right)
    }

    public func setMaster(_ volume: Double) {
        ss_playout_set_master(renderer, Float(max(0, min(1, volume))))
    }

    @discardableResult
    public func scheduleOverlay(_ mono: [Float], sampleRate: Double, startClusterNs: Int64) -> Bool {
        guard mono.count <= overlayCapacity else { return false }
        return mono.withUnsafeBufferPointer {
            ss_playout_schedule_overlay(renderer, $0.baseAddress, Int32(mono.count), sampleRate, startClusterNs) != 0
        }
    }

    public func stats() -> PlayoutStats {
        var s = ss_playout_stats()
        ss_playout_get_stats(renderer, &s)
        let (latency, trim) = lock.withLock { (outputLatencySeconds, trimSeconds) }
        return PlayoutStats(
            locked: s.locked != 0,
            errorMs: s.error_ms,
            ratioPpm: s.ratio_ppm,
            bufferMs: s.buffer_ms,
            delayMs: s.delay_ms,
            gain: Double(s.gain),
            mixL: Double(s.mix_l),
            mixR: Double(s.mix_r),
            peakDb: max(-120, s.peak > 0 ? 20 * log10(Double(s.peak)) : -120),
            underruns: Int(s.underruns),
            resyncs: Int(s.resyncs),
            outputLatencyMs: latency * 1000,
            trimMs: trim * 1000
        )
    }

    // MARK: Render (IO thread)

    /// Renders mono output. `hostNs` is when the first frame reaches the device output stage.
    @inline(__always)
    public func render(hostNs: Int64, into buffer: UnsafeMutablePointer<Float>, frames: Int, sampleRate: Double) {
        ss_playout_render(renderer, hostNs, buffer, Int32(frames), sampleRate)
    }

    /// Raw renderer pointer for IO callbacks that must avoid touching Swift objects.
    public var rendererPointer: OpaquePointer { renderer }
}
