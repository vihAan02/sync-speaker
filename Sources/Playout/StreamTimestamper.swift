import Foundation

/// Assigns absolute frame indices and smooth presentation times to captured blocks.
///
/// Capture callbacks report jittery host times; a sliding least-squares fit of host time against
/// frame index recovers the capture device's true rate relative to the host clock. Gaps (dropped
/// blocks, stalls) advance the frame index so the timeline stays aligned with wall time.
public struct StreamTimestamper: Sendable {
    public let nominalNsPerFrame: Double
    public let window: Int
    public let gapThresholdNs: Double

    private var entries: [(index: Int64, hostNs: Int64)] = []
    private var nextIndex: Int64 = 0
    private var fit: (originIndex: Int64, originNs: Int64, intercept: Double, slope: Double)?

    public init(sampleRate: Double, window: Int = 1_000, gapThresholdSeconds: Double = 0.02) {
        nominalNsPerFrame = 1e9 / sampleRate
        self.window = window
        gapThresholdNs = gapThresholdSeconds * 1e9
    }

    public var nsPerFrame: Double { fit?.slope ?? nominalNsPerFrame }

    /// Registers a captured block and returns the frame index of its first frame.
    public mutating func place(hostNs: Int64, frames: Int) -> Int64 {
        var index = nextIndex
        if !entries.isEmpty {
            let predicted = presentationNs(for: index)
            let late = Double(hostNs - predicted)
            if late > gapThresholdNs {
                index += Int64((late / nsPerFrame).rounded())
            } else if late < -gapThresholdNs * 10 {
                // Host time went backwards by a lot: capture restarted. Start a fresh fit.
                entries.removeAll()
                fit = nil
            }
        }
        entries.append((index, hostNs))
        if entries.count > window { entries.removeFirst(entries.count - window) }
        nextIndex = index + Int64(frames)
        refit()
        return index
    }

    /// Fitted host time (ns) of `index`.
    public func presentationNs(for index: Int64) -> Int64 {
        guard let fit else { return entries.last.map { $0.hostNs } ?? 0 }
        return fit.originNs + Int64((fit.intercept + fit.slope * Double(index - fit.originIndex)).rounded())
    }

    private mutating func refit() {
        guard let first = entries.first else { return }
        let n = Double(entries.count)
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        for e in entries {
            let x = Double(e.index - first.index)
            let y = Double(e.hostNs - first.hostNs)
            sx += x
            sy += y
            sxx += x * x
            sxy += x * y
        }
        let denom = n * sxx - sx * sx
        var slope = nominalNsPerFrame
        if entries.count >= 16, denom > 0 {
            slope = (n * sxy - sx * sy) / denom
            let limit = nominalNsPerFrame * 1e-3 // ±1000 ppm
            slope = min(max(slope, nominalNsPerFrame - limit), nominalNsPerFrame + limit)
        }
        let intercept = (sy - slope * sx) / n
        fit = (first.index, first.hostNs, intercept, slope)
    }
}

/// Re-slices captured blocks into fixed-size chunks with contiguous frame indices.
public struct StreamChunker: Sendable {
    public let framesPerChunk: Int
    public let channels: Int
    private var pending: [Float]
    private var pendingFrames = 0
    private var pendingStart: Int64 = 0

    public init(framesPerChunk: Int = 480, channels: Int = 2) {
        self.framesPerChunk = framesPerChunk
        self.channels = channels
        pending = [Float](repeating: 0, count: framesPerChunk * channels)
    }

    public mutating func append(frameIndex: Int64, interleaved: UnsafeBufferPointer<Float>,
                                emit: (Int64, UnsafeBufferPointer<Float>) -> Void) {
        let frames = interleaved.count / channels
        if pendingFrames > 0, frameIndex != pendingStart + Int64(pendingFrames) {
            flush(emit: emit)
        }
        if pendingFrames == 0 { pendingStart = frameIndex }
        var offset = 0
        while offset < frames {
            let take = min(framesPerChunk - pendingFrames, frames - offset)
            for i in 0..<(take * channels) {
                pending[pendingFrames * channels + i] = interleaved[offset * channels + i]
            }
            pendingFrames += take
            offset += take
            if pendingFrames == framesPerChunk { flush(emit: emit) }
        }
    }

    public mutating func flush(emit: (Int64, UnsafeBufferPointer<Float>) -> Void) {
        guard pendingFrames > 0 else { return }
        pending.withUnsafeBufferPointer {
            emit(pendingStart, UnsafeBufferPointer(rebasing: $0[0..<(pendingFrames * channels)]))
        }
        pendingStart += Int64(pendingFrames)
        pendingFrames = 0
    }
}
