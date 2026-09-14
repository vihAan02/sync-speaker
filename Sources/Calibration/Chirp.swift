import Accelerate
import Foundation

public enum Chirp {
    /// Linear sweep with a Tukey window. `up` sweeps f0→f1, otherwise f1→f0, so two speakers can
    /// play distinguishable chirps in the same recording.
    public static func samples(up: Bool, sampleRate: Double, duration: Double = 0.05, f0: Double = 4_000,
                               f1: Double = 16_000, amplitude: Float = 0.5, delay: Double = 0,
                               totalCount: Int? = nil) -> [Float] {
        let length = Int((duration * sampleRate).rounded())
        let count = totalCount ?? length
        var out = [Float](repeating: 0, count: count)
        let (start, end) = up ? (f0, f1) : (f1, f0)
        let k = (end - start) / duration
        for i in 0..<count {
            // Evaluated analytically so tests can place chirps at exact fractional delays.
            let t = Double(i) / sampleRate - delay
            guard t >= 0, t < duration else { continue }
            let phase = 2 * Double.pi * (start * t + 0.5 * k * t * t)
            out[i] = amplitude * Float(sin(phase)) * Float(tukey(t / duration, alpha: 0.2))
        }
        return out
    }

    static func tukey(_ x: Double, alpha: Double) -> Double {
        if x < alpha / 2 { return 0.5 * (1 - cos(2 * .pi * x / alpha)) }
        if x > 1 - alpha / 2 { return 0.5 * (1 - cos(2 * .pi * (1 - x) / alpha)) }
        return 1
    }
}

public enum MatchedFilter {
    public struct Detection: Equatable, Sendable {
        /// Seconds from the start of the recording to the start of the chirp.
        public var time: Double
        /// Peak correlation relative to the template's energy (≈ received amplitude ratio).
        public var strength: Double
        /// Peak over median absolute correlation.
        public var snr: Double
    }

    /// Finds the earliest strong arrival of `template` in `recording`.
    ///
    /// Reflections can exceed the direct path, so this takes the first envelope peak within
    /// `earliestWithinDb` of the global maximum rather than the maximum itself.
    public static func detect(template: [Float], in recording: [Float], sampleRate: Double,
                              earliestWithinDb: Double = 6) -> Detection? {
        let n = recording.count, m = template.count
        guard n > m, m > 4 else { return nil }
        let outCount = n - m + 1
        var corr = [Float](repeating: 0, count: outCount)
        recording.withUnsafeBufferPointer { r in
            template.withUnsafeBufferPointer { t in
                corr.withUnsafeMutableBufferPointer { c in
                    vDSP_conv(r.baseAddress!, 1, t.baseAddress!, 1, c.baseAddress!, 1, vDSP_Length(outCount), vDSP_Length(m))
                }
            }
        }

        var envelope = [Float](repeating: 0, count: outCount)
        vDSP_vabs(corr, 1, &envelope, 1, vDSP_Length(outCount))
        // Short max-hold turns the carrier-rate oscillation into an envelope.
        let hold = max(1, Int(sampleRate / 4_000))
        var smooth = envelope
        for i in 0..<outCount {
            var peak: Float = 0
            for j in max(0, i - hold)...min(outCount - 1, i + hold) { peak = max(peak, envelope[j]) }
            smooth[i] = peak
        }

        guard let globalMax = smooth.max(), globalMax > 0 else { return nil }
        let threshold = globalMax * Float(pow(10, -earliestWithinDb / 20))
        guard let firstAbove = smooth.firstIndex(where: { $0 >= threshold }) else { return nil }
        // Refine to the strongest raw-correlation sample within one hold window of the first crossing.
        let window = firstAbove...min(outCount - 1, firstAbove + 4 * hold)
        let peakIndex = window.max { abs(corr[$0]) < abs(corr[$1]) }!

        var location = Double(peakIndex)
        if peakIndex > 0, peakIndex < outCount - 1 {
            let y0 = Double(corr[peakIndex - 1]), y1 = Double(corr[peakIndex]), y2 = Double(corr[peakIndex + 1])
            let denom = y0 - 2 * y1 + y2
            if abs(denom) > 1e-12 {
                let delta = 0.5 * (y0 - y2) / denom
                if abs(delta) < 1 { location += delta }
            }
        }

        var energy: Float = 0
        vDSP_svesq(template, 1, &energy, vDSP_Length(m))
        let median = envelope.sorted()[outCount / 2]
        return Detection(
            time: location / sampleRate,
            strength: Double(abs(corr[peakIndex]) / max(energy, 1e-12)),
            snr: Double(globalMax / max(median, 1e-12))
        )
    }
}
