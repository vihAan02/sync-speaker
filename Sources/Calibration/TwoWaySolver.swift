import Foundation

/// Solves speaker spacing and residual playback offset from a two-speaker chirp exchange.
///
/// Speaker A plays at cluster time T, speaker B at T + stagger. Each node measures, inside its own
/// recording, `x = arrival(B) - arrival(A)`. Emission latencies and each node's recording clock cancel:
///
///     xA = S + (ℓB − ℓA) + D − sA        xB = S + (ℓB − ℓA) − D + sB
///
/// where D is the acoustic travel time between the nodes and s is each node's own mic-to-speaker time.
public enum TwoWaySolver {
    public struct Result: Equatable, Sendable {
        public var distanceMeters: Double
        /// How much later B actually plays than A for the same scheduled time, in seconds.
        public var bLateBySeconds: Double
    }

    public static func solve(xA: Double, xB: Double, staggerSeconds: Double, selfPathA: Double = 0,
                             selfPathB: Double = 0, speedOfSound: Double = 343) -> Result {
        let travel = (xA - xB + selfPathA + selfPathB) / 2
        let bLate = (xA + xB) / 2 - staggerSeconds + (selfPathA - selfPathB) / 2
        return Result(distanceMeters: max(0, travel) * speedOfSound, bLateBySeconds: bLate)
    }
}
