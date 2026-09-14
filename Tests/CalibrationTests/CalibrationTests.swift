import Foundation
import Testing
@testable import Calibration

@Suite struct CalibrationTests {
    let fs = 48_000.0

    /// A node's recording: its own chirp at `ownDelay` plus the other node's at `otherDelay`, with a
    /// weaker wall reflection and background noise.
    func recording(upAt: Double, downAt: Double, upGain: Float, downGain: Float, noise: Float,
                   seconds: Double = 1.2, seed: UInt64) -> [Float] {
        let count = Int(seconds * fs)
        let up = Chirp.samples(up: true, sampleRate: fs, amplitude: upGain, delay: upAt, totalCount: count)
        let upEcho = Chirp.samples(up: true, sampleRate: fs, amplitude: upGain * 0.4, delay: upAt + 0.0071, totalCount: count)
        let down = Chirp.samples(up: false, sampleRate: fs, amplitude: downGain, delay: downAt, totalCount: count)
        let downEcho = Chirp.samples(up: false, sampleRate: fs, amplitude: downGain * 0.4, delay: downAt + 0.0093, totalCount: count)
        var state = seed
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let n = (Float(state >> 40) / Float(1 << 24) - 0.5) * 2 * noise
            return up[i] + upEcho[i] + down[i] + downEcho[i] + n
        }
    }

    @Test func detectsFractionalArrival() throws {
        let rec = recording(upAt: 0.2503125, downAt: 0.61, upGain: 0.3, downGain: 0.1, noise: 0.02, seed: 1)
        let template = Chirp.samples(up: true, sampleRate: fs)
        let hit = try #require(MatchedFilter.detect(template: template, in: rec, sampleRate: fs))
        #expect(abs(hit.time - 0.2503125) < 5e-6, "got \(hit.time)")
    }

    @Test func upAndDownChirpsAreDistinguishable() throws {
        let rec = recording(upAt: 0.30, downAt: 0.55, upGain: 0.02, downGain: 0.5, noise: 0.01, seed: 2)
        let up = try #require(MatchedFilter.detect(template: Chirp.samples(up: true, sampleRate: fs), in: rec, sampleRate: fs))
        #expect(abs(up.time - 0.30) < 2e-5, "a loud down-chirp must not mask a quiet up-chirp; got \(up.time)")
    }

    @Test func solvesDistanceAndLatencyEndToEnd() throws {
        // Ground truth.
        let distance = 1.37 // meters
        let travel = distance / 343
        let latencyA = 0.0112, latencyB = 0.0149 // B is 3.7 ms late
        let stagger = 0.25
        let chirpAt = 0.3 // scheduled time of A's chirp inside both recordings (recording clocks differ below)
        let selfPath = 0.00006

        // Node A's recording starts 0 ms after T0; node B's recording starts 17.3 ms after T0 on its own clock.
        let recA = recording(upAt: chirpAt + latencyA + selfPath, downAt: chirpAt + stagger + latencyB + travel,
                             upGain: 0.4, downGain: 0.08, noise: 0.01, seed: 3)
        let offsetB = -0.0173
        let recB = recording(upAt: chirpAt + latencyA + travel + offsetB, downAt: chirpAt + stagger + latencyB + selfPath + offsetB,
                             upGain: 0.08, downGain: 0.4, noise: 0.01, seed: 4)

        let up = Chirp.samples(up: true, sampleRate: fs)
        let down = Chirp.samples(up: false, sampleRate: fs)
        func x(_ rec: [Float]) throws -> Double {
            let a = try #require(MatchedFilter.detect(template: up, in: rec, sampleRate: fs))
            let b = try #require(MatchedFilter.detect(template: down, in: rec, sampleRate: fs))
            return b.time - a.time
        }
        let result = TwoWaySolver.solve(xA: try x(recA), xB: try x(recB), staggerSeconds: stagger,
                                        selfPathA: selfPath, selfPathB: selfPath)
        #expect(abs(result.distanceMeters - distance) < 0.01, "distance \(result.distanceMeters)")
        #expect(abs(result.bLateBySeconds - (latencyB - latencyA)) < 0.0001, "latency \(result.bLateBySeconds)")
    }
}
