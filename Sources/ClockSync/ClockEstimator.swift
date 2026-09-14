import Foundation

/// Maps local host time to cluster (leader) time: `cluster = clusterRef + (local - localRef) * rate`.
public struct ClockMap: Equatable, Sendable {
    public var localRefNs: Int64
    public var clusterRefNs: Int64
    public var rate: Double

    public static let identity = ClockMap(localRefNs: 0, clusterRefNs: 0, rate: 1)

    public init(localRefNs: Int64, clusterRefNs: Int64, rate: Double) {
        self.localRefNs = localRefNs
        self.clusterRefNs = clusterRefNs
        self.rate = rate
    }

    public func toCluster(_ localNs: Int64) -> Int64 {
        clusterRefNs + Int64((Double(localNs - localRefNs) * rate).rounded())
    }

    public func toLocal(_ clusterNs: Int64) -> Int64 {
        localRefNs + Int64((Double(clusterNs - clusterRefNs) / rate).rounded())
    }
}

/// NTP-style offset estimator tuned for Wi-Fi.
///
/// Every `blockSize` exchanges, the one with the smallest round trip becomes a "good" sample (its path
/// asymmetry is the least polluted by queueing). Offset and skew come from a round-trip-weighted
/// least-squares line through the last `historySize` good samples, after rejecting outliers.
public struct ClockEstimator: Sendable {
    public struct Exchange: Sendable {
        public var t1: Int64, t2: Int64, t3: Int64, t4: Int64

        public init(t1: Int64, t2: Int64, t3: Int64, t4: Int64) {
            self.t1 = t1
            self.t2 = t2
            self.t3 = t3
            self.t4 = t4
        }

        /// Remote minus local, in ns.
        public var offset: Double { (Double(t2 - t1) + Double(t3 - t4)) / 2 }
        public var roundTrip: Int64 { (t4 - t1) - (t3 - t2) }
        public var localMidpoint: Int64 { t1 + (t4 - t1) / 2 }
    }

    struct GoodSample: Sendable {
        var local: Int64
        var offset: Double
        var roundTrip: Int64
    }

    public let blockSize: Int
    public let historySize: Int
    private var block: [Exchange] = []
    private var good: [GoodSample] = []
    public private(set) var map: ClockMap?
    public private(set) var stats = Stats()

    public struct Stats: Sendable, Equatable {
        public var offsetNs: Double = 0
        public var jitterNs: Double = 0
        public var roundTripNs: Double = 0
        public var skewPpm: Double = 0
        public var goodSamples: Int = 0

        public init(offsetNs: Double = 0, jitterNs: Double = 0, roundTripNs: Double = 0, skewPpm: Double = 0,
                    goodSamples: Int = 0) {
            self.offsetNs = offsetNs
            self.jitterNs = jitterNs
            self.roundTripNs = roundTripNs
            self.skewPpm = skewPpm
            self.goodSamples = goodSamples
        }
    }

    public init(blockSize: Int = 16, historySize: Int = 96) {
        self.blockSize = blockSize
        self.historySize = historySize
    }

    /// Adds one exchange. Returns true when the map was updated.
    @discardableResult
    public mutating func add(_ exchange: Exchange) -> Bool {
        guard exchange.roundTrip >= 0 else { return false }
        block.append(exchange)
        // Bootstrap quickly: until we have a few good samples, promote smaller blocks.
        let needed = good.count < 4 ? max(2, blockSize / 4) : blockSize
        guard block.count >= needed else { return false }
        let best = block.min { $0.roundTrip < $1.roundTrip }!
        block.removeAll(keepingCapacity: true)
        good.append(GoodSample(local: best.localMidpoint, offset: best.offset, roundTrip: best.roundTrip))
        if good.count > historySize { good.removeFirst(good.count - historySize) }
        refit()
        return true
    }

    public mutating func reset() {
        block.removeAll()
        good.removeAll()
        map = nil
        stats = Stats()
    }

    private mutating func refit() {
        var samples = good
        // Reject samples whose round trip is far above the recent minimum (congestion episodes).
        if let minRTT = samples.map(\.roundTrip).min(), samples.count >= 8 {
            let limit = Double(minRTT) * 2 + 2_000_000
            let kept = samples.filter { Double($0.roundTrip) <= limit }
            if kept.count >= 4 { samples = kept }
        }

        var fit = Self.lineFit(samples)
        if samples.count >= 8 {
            // One pass of residual-based outlier rejection.
            let residuals = samples.map { abs($0.offset - fit.value(at: $0.local)) }
            let mad = Self.median(residuals)
            let kept = zip(samples, residuals).filter { $0.1 <= max(3 * mad, 50_000) }.map(\.0)
            if kept.count >= 4 {
                samples = kept
                fit = Self.lineFit(samples)
            }
        }

        let refLocal = good.last!.local
        let offsetAtRef = fit.value(at: refLocal)
        map = ClockMap(
            localRefNs: refLocal,
            clusterRefNs: refLocal + Int64(offsetAtRef.rounded()),
            rate: 1 + fit.slope
        )
        let residuals = samples.map { $0.offset - fit.value(at: $0.local) }
        let rms = sqrt(residuals.reduce(0) { $0 + $1 * $1 } / Double(max(1, residuals.count)))
        stats = Stats(
            offsetNs: offsetAtRef,
            jitterNs: rms,
            roundTripNs: Double(samples.map(\.roundTrip).min() ?? 0),
            skewPpm: fit.slope * 1e6,
            goodSamples: good.count
        )
    }

    struct Line {
        var originLocal: Int64
        var intercept: Double
        var slope: Double

        func value(at local: Int64) -> Double {
            intercept + slope * Double(local - originLocal)
        }
    }

    /// Weighted least squares. A sample's worst-case path asymmetry is bounded by its round trip, so
    /// samples near the minimum round trip get most of the weight.
    static func lineFit(_ samples: [GoodSample]) -> Line {
        let origin = samples.first!.local
        let minRTT = Double(samples.map(\.roundTrip).min()!)
        let weights = samples.map { s -> Double in
            let excess = Double(s.roundTrip) - minRTT + 200_000
            return 1 / (excess * excess)
        }
        let sw = weights.reduce(0, +)
        guard samples.count >= 4 else {
            // Too few points for a stable slope: offset only.
            let mean = zip(samples, weights).reduce(0) { $0 + $1.0.offset * $1.1 } / sw
            return Line(originLocal: origin, intercept: mean, slope: 0)
        }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for (s, w) in zip(samples, weights) {
            let x = Double(s.local - origin)
            sx += w * x
            sy += w * s.offset
            sxx += w * x * x
            sxy += w * x * s.offset
        }
        let denom = sw * sxx - sx * sx
        guard denom > 0 else { return Line(originLocal: origin, intercept: sy / sw, slope: 0) }
        var slope = (sw * sxy - sx * sy) / denom
        // Crystal oscillators stay well inside ±500 ppm; anything else is noise.
        slope = max(-500e-6, min(500e-6, slope))
        let intercept = (sy - slope * sx) / sw
        return Line(originLocal: origin, intercept: intercept, slope: slope)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}
