import Foundation

/// One-euro filter (Casiez et al.): heavy smoothing when still, low lag when moving.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double
    private var x: Double?
    private var dx: Double = 0
    private var lastTime: Double?

    public init(minCutoff: Double = 0.5, beta: Double = 0.8, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func filter(_ value: Double, time: Double) -> Double {
        guard let prev = x, let last = lastTime, time > last else {
            x = value
            lastTime = time
            return value
        }
        let dt = time - last
        let rawDx = (value - prev) / dt
        dx += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let next = prev + Self.alpha(cutoff: cutoff, dt: dt) * (value - prev)
        x = next
        lastTime = time
        return next
    }

    public mutating func reset() {
        x = nil
        dx = 0
        lastTime = nil
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

public struct OneEuroFilter2D: Sendable {
    private var fx: OneEuroFilter
    private var fz: OneEuroFilter

    public init(minCutoff: Double = 0.5, beta: Double = 0.8) {
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta)
        fz = OneEuroFilter(minCutoff: minCutoff, beta: beta)
    }

    public mutating func filter(_ p: Vec2, time: Double) -> Vec2 {
        Vec2(fx.filter(p.x, time: time), fz.filter(p.z, time: time))
    }

    public mutating func reset() {
        fx.reset()
        fz.reset()
    }
}
