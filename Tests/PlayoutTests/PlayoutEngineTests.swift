import Foundation
import Testing
@testable import Playout
import SyncProtocol

/// Drives a PlayoutEngine the way the real system does: a "leader" produces timestamped chunks and an
/// "output device" renders against its own (drifting) sample clock.
struct PlayoutSimulation {
    let engine = PlayoutEngine()
    let sourceRate = 48_000.0
    let outputRate: Double
    let outputDriftPpm: Double
    var playoutLatencyNs: Int64 = 300_000_000
    let tone = 441.0

    var sourceFrames: Int64 = 0
    var hostNs: Int64 = 1_000_000_000_000
    var outputFramesRendered: Int64 = 0

    init(outputRate: Double = 48_000, outputDriftPpm: Double = 0) {
        self.outputRate = outputRate
        self.outputDriftPpm = outputDriftPpm
        engine.setClockMap(localRefNs: 0, clusterRefNs: 0, rate: 1)
        engine.setRender(SpeakerRender(delaySeconds: 0, gain: 1, channel: .left))
    }

    func sourceSample(_ frame: Int64) -> Float {
        Float(sin(2 * Double.pi * tone * Double(frame) / sourceRate)) * 0.5
    }

    /// Produces source audio up to `untilNs` + playout latency, 480 frames at a time.
    mutating func feed(untilNs: Int64, startNs: Int64) {
        let npf = 1e9 / sourceRate
        while Double(sourceFrames) * npf + Double(startNs) < Double(untilNs + playoutLatencyNs + 100_000_000) {
            var chunk = [Float](repeating: 0, count: 960)
            for i in 0..<480 {
                let s = sourceSample(sourceFrames + Int64(i))
                chunk[i * 2] = s
                chunk[i * 2 + 1] = -s
            }
            let pts = startNs + Int64(Double(sourceFrames) * npf) + playoutLatencyNs
            let header = AudioChunkHeader(channels: 2, format: .float32, sampleRate: 48_000, epoch: 1,
                                          frameIndex: sourceFrames, ptsNs: pts, nsPerFrame: npf)
            chunk.withUnsafeBufferPointer { engine.ingest(header: header, samples: $0) }
            sourceFrames += 480
        }
    }

    /// Renders `seconds` of output; returns (output samples, host time of each block start).
    mutating func run(seconds: Double, block: Int = 512, startNs: Int64) -> [(hostNs: Int64, samples: [Float])] {
        var out: [(Int64, [Float])] = []
        let blocks = Int(seconds * outputRate) / block
        // The device's true period differs from nominal by the drift.
        let truePeriodNs = 1e9 / (outputRate * (1 + outputDriftPpm * 1e-6))
        var buffer = [Float](repeating: 0, count: block)
        for _ in 0..<blocks {
            let host = hostNs + Int64(Double(outputFramesRendered) * truePeriodNs)
            feed(untilNs: host, startNs: startNs)
            buffer.withUnsafeMutableBufferPointer {
                engine.render(hostNs: host, into: $0.baseAddress!, frames: block, sampleRate: outputRate)
            }
            out.append((host, buffer))
            outputFramesRendered += Int64(block)
        }
        return out
    }
}

@Suite struct PlayoutEngineTests {
    /// Phase error (seconds) between rendered audio and the ideal source at that time.
    func alignmentError(_ blocks: [(hostNs: Int64, samples: [Float])], sim: PlayoutSimulation, startNs: Int64,
                        truePeriodNs: Double) -> Double {
        // Cross-correlate the last block against the ideal tone at lags within half a tone period.
        let (host, samples) = blocks.last!
        var bestLag = 0.0
        var best = -Double.infinity
        for lagUs in stride(from: -1000.0, through: 1000.0, by: 5) {
            var acc = 0.0
            for (k, y) in samples.enumerated() {
                let emitNs = Double(host) + Double(k) * truePeriodNs
                let sourceTime = (emitNs - Double(sim.playoutLatencyNs) - Double(startNs)) / 1e9 + lagUs * 1e-6
                acc += Double(y) * sin(2 * Double.pi * sim.tone * sourceTime)
            }
            if acc > best {
                best = acc
                bestLag = lagUs
            }
        }
        return bestLag * 1e-6
    }

    @Test func locksAndTracksDriftingOutputClock() {
        var sim = PlayoutSimulation(outputDriftPpm: 80)
        let start = sim.hostNs
        let blocks = sim.run(seconds: 120, startNs: start)
        let stats = sim.engine.stats()
        #expect(stats.locked)
        #expect(abs(stats.errorMs) < 0.2, "error \(stats.errorMs) ms")
        #expect(abs(stats.ratioPpm + 80) < 10, "correction \(stats.ratioPpm) ppm")
        #expect(stats.resyncs == 0)
        let lag = alignmentError(blocks, sim: sim, startNs: start, truePeriodNs: 1e9 / (48_000 * (1 + 80e-6)))
        #expect(abs(lag) < 0.0002, "audible alignment error \(lag * 1000) ms")
    }

    @Test func convertsSampleRates() {
        var sim = PlayoutSimulation(outputRate: 44_100)
        let start = sim.hostNs
        let blocks = sim.run(seconds: 5, block: 441, startNs: start)
        #expect(sim.engine.stats().underruns == 0)
        let lag = alignmentError(blocks, sim: sim, startNs: start, truePeriodNs: 1e9 / 44_100)
        #expect(abs(lag) < 0.0002)
    }

    @Test func latencyChangeResyncsQuickly() {
        var sim = PlayoutSimulation()
        let start = sim.hostNs
        _ = sim.run(seconds: 2, startNs: start)
        // The leader lowers playout latency by 10 ms: new chunks carry earlier timestamps.
        sim.playoutLatencyNs -= 10_000_000
        _ = sim.run(seconds: 1, startNs: start)
        let stats = sim.engine.stats()
        #expect(stats.resyncs == 1)
        #expect(abs(stats.errorMs) < 0.1, "should jump, not slew for ~50 s; error \(stats.errorMs) ms")
    }

    @Test func spatialDelayIsSlewLimited() {
        var sim = PlayoutSimulation()
        let start = sim.hostNs
        _ = sim.run(seconds: 1, startNs: start)
        sim.engine.setRender(SpeakerRender(delaySeconds: 0.004, gain: 1, channel: .left))
        _ = sim.run(seconds: 2, startNs: start)
        let partial = sim.engine.stats().delayMs
        #expect(abs(partial - 2.0) < 0.05, "1 ms/s slew should reach ~2 ms after 2 s, got \(partial)")
        _ = sim.run(seconds: 3, startNs: start)
        #expect(abs(sim.engine.stats().delayMs - 4.0) < 1e-6)
        #expect(sim.engine.stats().resyncs == 0)
    }

    @Test func channelRoutingSelectsSourceChannel() {
        var sim = PlayoutSimulation()
        let start = sim.hostNs
        let left = sim.run(seconds: 1, startNs: start).last!.samples
        sim.engine.setRender(SpeakerRender(delaySeconds: 0, gain: 1, channel: .right))
        let right = sim.run(seconds: 2, startNs: start).last!.samples
        #expect(left.contains { abs($0) > 0.3 })
        // Right channel is the inverted tone.
        let host = sim.hostNs + Int64(Double(sim.outputFramesRendered - 512) * 1e9 / 48_000)
        let ideal = (0..<512).map { k -> Float in
            let t = (Double(host) + Double(k) * 1e9 / 48_000 - Double(sim.playoutLatencyNs) - Double(start)) / 1e9
            return -Float(sin(2 * Double.pi * sim.tone * t)) * 0.5
        }
        let err = zip(right, ideal).map { abs($0 - $1) }.max()!
        #expect(err < 0.02, "max deviation \(err)")
    }

    @Test func overlayStartsAtScheduledClusterTime() {
        let engine = PlayoutEngine()
        engine.setClockMap(localRefNs: 0, clusterRefNs: 0, rate: 1)
        engine.setOutputLatency(seconds: 0.010)
        let click = [Float](repeating: 1, count: 48)
        // Output stage host time 0 → leaves the speaker at 10 ms. Schedule at 30 ms → frame 960.
        #expect(engine.scheduleOverlay(click, sampleRate: 48_000, startClusterNs: 30_000_000))
        var buffer = [Float](repeating: 0, count: 2048)
        buffer.withUnsafeMutableBufferPointer {
            engine.render(hostNs: 0, into: $0.baseAddress!, frames: 2048, sampleRate: 48_000)
        }
        #expect(buffer.firstIndex { $0 > 0.5 } == 960)
    }

    @Test func epochChangeResetsTimeline() throws {
        var sim = PlayoutSimulation()
        let start = sim.hostNs
        _ = sim.run(seconds: 1, startNs: start)
        #expect(sim.engine.stats().locked)
        let header = AudioChunkHeader(channels: 2, format: .float32, sampleRate: 48_000, epoch: 2,
                                      frameIndex: 0, ptsNs: 0, nsPerFrame: 1e9 / 48_000)
        [Float](repeating: 0, count: 960).withUnsafeBufferPointer { sim.engine.ingest(header: header, samples: $0) }
        var buffer = [Float](repeating: 0, count: 512)
        buffer.withUnsafeMutableBufferPointer {
            sim.engine.render(hostNs: sim.hostNs, into: $0.baseAddress!, frames: 512, sampleRate: 48_000)
        }
        #expect(buffer.allSatisfy { $0 == 0 })
    }
}

@Suite struct StreamTimestamperTests {
    @Test func recoversCaptureRateFromJitteryTimestamps() {
        var ts = StreamTimestamper(sampleRate: 48_000)
        var rng = SplitMix(seed: 0x5EED)
        let truePeriod = 1e9 / (48_000 * (1 - 35e-6))
        var frames: Int64 = 0
        for _ in 0..<2_000 {
            let ideal = 10_000_000_000 + Int64(Double(frames) * truePeriod)
            let jitter = Int64.random(in: -400_000...400_000, using: &rng)
            let index = ts.place(hostNs: ideal + jitter, frames: 512)
            #expect(index == frames)
            frames += 512
        }
        // ±400 µs uniform jitter over a ~10 s window bounds the slope to a few ppm.
        #expect(abs(ts.nsPerFrame / truePeriod - 1) < 10e-6)
        let predicted = ts.presentationNs(for: frames)
        let ideal = 10_000_000_000 + Int64(Double(frames) * truePeriod)
        #expect(abs(predicted - ideal) < 100_000)
    }

    @Test func gapAdvancesFrameIndex() {
        var ts = StreamTimestamper(sampleRate: 48_000)
        let period = 1e9 / 48_000
        var host: Int64 = 0
        for i in 0..<100 {
            _ = ts.place(hostNs: host, frames: 480)
            host += Int64(480 * period)
            if i == 99 { host += 100_000_000 } // 100 ms stall
        }
        let index = ts.place(hostNs: host, frames: 480)
        #expect(abs(index - (100 * 480 + 4_800)) <= 1)
    }

    @Test func chunkerProducesContiguousFixedChunks() {
        var chunker = StreamChunker(framesPerChunk: 480, channels: 2)
        var emitted: [(Int64, Int)] = []
        let block = [Float](repeating: 0.25, count: 512 * 2)
        for i in 0..<10 {
            block.withUnsafeBufferPointer { buf in
                chunker.append(frameIndex: Int64(i * 512), interleaved: buf) { emitted.append(($0, $1.count / 2)) }
            }
        }
        #expect(emitted.count == 10)
        #expect(emitted.allSatisfy { $0.1 == 480 })
        #expect(zip(emitted, emitted.dropFirst()).allSatisfy { $0.0 + 480 == $1.0 })
    }
}

struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
