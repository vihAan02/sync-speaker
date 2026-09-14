import Foundation
import Testing
@testable import ClockSync

/// Deterministic xorshift so failures are reproducible.
struct TestRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

@Suite struct ClockEstimatorTests {
    /// Simulates a follower whose clock is offset and skewed from the leader over a jittery link.
    func simulate(offsetNs: Double, skewPpm: Double, seconds: Double, meanJitterMs: Double,
                  seed: UInt64 = 42) -> (ClockEstimator, (Int64) -> Int64) {
        var rng = TestRNG(state: seed)
        var estimator = ClockEstimator()
        let rate = 1 + skewPpm * 1e-6
        // leader(local) = local * rate + offset
        let leader: (Int64) -> Int64 = { Int64(Double($0) * rate + offsetNs) }
        func delayNs() -> Int64 {
            let base = 1_500_000.0 // 1.5 ms one-way floor
            let u = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            return Int64(base + -log(u) * meanJitterMs * 1e6) // exponential queueing
        }
        var local: Int64 = 5_000_000_000_000
        let steps = Int(seconds * 10)
        for _ in 0..<steps {
            let t1 = local
            let t2 = leader(t1 + delayNs())
            let t3 = t2 + 50_000
            let t4 = Int64((Double(t3) - offsetNs) / rate) + delayNs()
            estimator.add(.init(t1: t1, t2: t2, t3: t3, t4: t4))
            local += 100_000_000
        }
        return (estimator, leader)
    }

    @Test(arguments: [1, 7, 42, 1234, 9999] as [UInt64])
    func convergesUnderWiFiJitter(seed: UInt64) throws {
        let (estimator, leader) = simulate(offsetNs: 123_456_789, skewPpm: 40, seconds: 90, meanJitterMs: 2, seed: seed)
        let map = try #require(estimator.map)
        let probe: Int64 = 5_000_000_000_000 + 90_000_000_000
        let errorNs = Double(map.toCluster(probe) - leader(probe))
        #expect(abs(errorNs) < 100_000, "clock error \(errorNs / 1e3) µs")
        #expect(abs(estimator.stats.skewPpm - 40) < 5, "skew \(estimator.stats.skewPpm) ppm")
    }

    @Test func producesMapQuickly() {
        let (estimator, _) = simulate(offsetNs: -2e9, skewPpm: -25, seconds: 1, meanJitterMs: 2)
        #expect(estimator.map != nil)
    }

    @Test func extrapolatesAcrossShortGaps() throws {
        let (estimator, leader) = simulate(offsetNs: 7e6, skewPpm: 60, seconds: 120, meanJitterMs: 1)
        let map = try #require(estimator.map)
        // 5 s after the last exchange, skew compensation keeps us within a quarter millisecond.
        let probe: Int64 = 5_000_000_000_000 + 125_000_000_000
        #expect(abs(Double(map.toCluster(probe) - leader(probe))) < 250_000)
    }

    @Test func mapRoundTrips() {
        let map = ClockMap(localRefNs: 1_000, clusterRefNs: 9_000_000, rate: 1.00005)
        let local: Int64 = 777_777_777_777
        #expect(abs(map.toLocal(map.toCluster(local)) - local) <= 1)
    }
}
