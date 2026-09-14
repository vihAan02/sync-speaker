import AudioIO
import Foundation
import Playout
import SyncProtocol
import Transport

/// Leader audio pipeline: source blocks → timestamps → 10 ms chunks → local timeline + followers.
final class LeaderSource: @unchecked Sendable {
    enum Kind: String {
        /// Everything the Mac plays (AirPlay Receiver, Music.app), muted at the hardware.
        case systemTap = "tap"
        /// Alternating left/right clicks, for sync tests without a music source.
        case testTone = "tone"
    }

    struct Stats {
        var active = false
        var sampleRate = 0.0
        var levelDb = -120.0
        var dropped = 0
        var error: String?
    }

    let kind: Kind
    private let engine: PlayoutEngine
    private let link: LinkServer
    private let playoutLatencyNs: @Sendable () -> Int64
    private let tap = SystemAudioTap()
    private var thread: Thread?
    private let lock = NSLock()
    private var stats = Stats()

    init(kind: Kind, engine: PlayoutEngine, link: LinkServer, playoutLatencyNs: @escaping @Sendable () -> Int64) {
        self.kind = kind
        self.engine = engine
        self.link = link
        self.playoutLatencyNs = playoutLatencyNs
    }

    var currentStats: Stats {
        lock.withLock {
            var s = stats
            s.dropped += Int(kind == .systemTap ? tap.droppedBlocks : 0)
            return s
        }
    }

    func start() throws {
        let rate: Double
        switch kind {
        case .systemTap:
            do {
                try tap.start(mute: true)
            } catch {
                lock.withLock { stats.error = "\(error)" }
                throw error
            }
            rate = tap.sampleRate
        case .testTone:
            rate = 48_000
        }
        lock.withLock { stats = Stats(active: true, sampleRate: rate) }
        let thread = Thread { [weak self] in self?.run(sampleRate: rate) }
        thread.qualityOfService = .userInteractive
        thread.name = "syncspeaker.leader.source"
        thread.start()
        self.thread = thread
    }

    func stop() {
        thread?.cancel()
        thread = nil
        tap.stop()
        lock.withLock { stats.active = false }
    }

    private func run(sampleRate: Double) {
        let maxFrames = tap.maxBlockFrames
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
        defer { buffer.deallocate() }
        var timestamper = StreamTimestamper(sampleRate: sampleRate)
        var chunker = StreamChunker(framesPerChunk: 480, channels: 2)
        let epoch = UInt32.random(in: 1...UInt32.max)
        var tone = ToneGenerator(sampleRate: sampleRate)
        var peak: Float = 0
        var peakFrames = 0

        while !Thread.current.isCancelled {
            let block: (frames: Int, hostNs: Int64)?
            switch kind {
            case .systemTap: block = tap.pop(into: buffer, capacityFrames: maxFrames)
            case .testTone: block = tone.next(into: buffer, maxFrames: maxFrames)
            }
            guard let block else {
                usleep(2_000)
                continue
            }

            for i in 0..<(block.frames * 2) { peak = max(peak, abs(buffer[i])) }
            peakFrames += block.frames
            if peakFrames >= Int(sampleRate / 5) {
                let db = peak > 0 ? max(-120, 20 * log10(Double(peak))) : -120
                // Peak meter with ~15 dB/s release so short transients stay readable.
                lock.withLock { stats.levelDb = max(db, stats.levelDb - 3) }
                peak = 0
                peakFrames = 0
            }

            let index = timestamper.place(hostNs: block.hostNs, frames: block.frames)
            let latency = playoutLatencyNs()
            chunker.append(frameIndex: index, interleaved: UnsafeBufferPointer(start: buffer, count: block.frames * 2)) {
                start, samples in
                let header = AudioChunkHeader(
                    channels: 2, format: .int16, sampleRate: UInt32(sampleRate), epoch: epoch, frameIndex: start,
                    ptsNs: timestamper.presentationNs(for: start) + latency, nsPerFrame: timestamper.nsPerFrame)
                engine.ingest(header: header, samples: samples)
                link.broadcastAudio(AudioChunkCodec.encode(header: header, samples: samples))
            }
        }
    }
}

/// Paced synthetic source: a 20 ms 1 kHz tone burst every 500 ms, alternating left and right.
struct ToneGenerator {
    let sampleRate: Double
    private var framesProduced: Int64 = 0
    private var startNs: Int64 = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    mutating func next(into buffer: UnsafeMutablePointer<Float>, maxFrames: Int) -> (frames: Int, hostNs: Int64)? {
        let now = HostClock.nowNs()
        if startNs == 0 { startNs = now }
        let due = Int64(Double(now - startNs) / 1e9 * sampleRate)
        let frames = Int(min(Int64(maxFrames), due - framesProduced))
        guard frames >= 256 else { return nil }
        let half = Int64(sampleRate / 2)
        let burst = Int64(sampleRate * 0.02)
        for f in 0..<frames {
            let n = framesProduced + Int64(f)
            let phase = n % half
            let inBurst = phase < burst
            let env = inBurst ? Float(sin(Double.pi * Double(phase) / Double(burst))) : 0
            let s = env * 0.5 * Float(sin(2 * Double.pi * 1_000 * Double(n) / sampleRate))
            let left = (n / half) % 2 == 0
            buffer[f * 2] = left ? s : 0
            buffer[f * 2 + 1] = left ? 0 : s
        }
        let hostNs = startNs + Int64(Double(framesProduced) / sampleRate * 1e9)
        framesProduced += Int64(frames)
        return (frames, hostNs)
    }
}
