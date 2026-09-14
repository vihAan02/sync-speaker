import Foundation

public enum SampleFormat: UInt8, Sendable {
    case int16 = 0
    case float32 = 1

    public var bytesPerSample: Int { self == .int16 ? 2 : 4 }
}

/// Fixed 40-byte little-endian header in front of every audio chunk.
public struct AudioChunkHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x5353_4155 // "SSAU"
    public static let size = 40

    public var channels: UInt8
    public var format: SampleFormat
    public var sampleRate: UInt32
    /// Changes whenever the leader restarts capture; receivers reset their timeline.
    public var epoch: UInt32
    /// Absolute index of the first frame in this chunk.
    public var frameIndex: Int64
    /// Cluster time at which `frameIndex` should leave the speakers.
    public var ptsNs: Int64
    /// Cluster nanoseconds between frames, as measured at capture.
    public var nsPerFrame: Double

    public init(channels: UInt8, format: SampleFormat, sampleRate: UInt32, epoch: UInt32,
                frameIndex: Int64, ptsNs: Int64, nsPerFrame: Double) {
        self.channels = channels
        self.format = format
        self.sampleRate = sampleRate
        self.epoch = epoch
        self.frameIndex = frameIndex
        self.ptsNs = ptsNs
        self.nsPerFrame = nsPerFrame
    }
}

public enum AudioChunkCodec {
    public enum DecodeError: Error { case tooShort, badMagic, badFormat, badLength }

    /// Encodes interleaved float samples; values are clipped to [-1, 1] for int16.
    public static func encode(header: AudioChunkHeader, samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(capacity: AudioChunkHeader.size + samples.count * header.format.bytesPerSample)
        data.appendLE(AudioChunkHeader.magic)
        data.append(1) // version
        data.append(header.channels)
        data.append(header.format.rawValue)
        data.append(0)
        data.appendLE(header.sampleRate)
        data.appendLE(header.epoch)
        data.appendLE(UInt64(bitPattern: header.frameIndex))
        data.appendLE(UInt64(bitPattern: header.ptsNs))
        data.appendLE(header.nsPerFrame.bitPattern)
        switch header.format {
        case .int16:
            for s in samples {
                let v = Int16(max(-1, min(1, s)) * 32767)
                data.appendLE(UInt16(bitPattern: v))
            }
        case .float32:
            for s in samples { data.appendLE(s.bitPattern) }
        }
        return data
    }

    public static func decodeHeader(_ data: Data) throws -> AudioChunkHeader {
        guard data.count >= AudioChunkHeader.size else { throw DecodeError.tooShort }
        return try data.withUnsafeBytes { raw in
            guard raw.loadLE(UInt32.self, at: 0) == AudioChunkHeader.magic else { throw DecodeError.badMagic }
            guard let format = SampleFormat(rawValue: raw[6]) else { throw DecodeError.badFormat }
            return AudioChunkHeader(
                channels: raw[5],
                format: format,
                sampleRate: raw.loadLE(UInt32.self, at: 8),
                epoch: raw.loadLE(UInt32.self, at: 12),
                frameIndex: Int64(bitPattern: raw.loadLE(UInt64.self, at: 16)),
                ptsNs: Int64(bitPattern: raw.loadLE(UInt64.self, at: 24)),
                nsPerFrame: Double(bitPattern: raw.loadLE(UInt64.self, at: 32))
            )
        }
    }

    /// Decodes the sample payload into `out` (interleaved floats). Returns the frame count.
    public static func decodeSamples(_ data: Data, header: AudioChunkHeader, into out: inout [Float]) throws -> Int {
        let payload = data.count - AudioChunkHeader.size
        let bytesPerFrame = header.format.bytesPerSample * Int(header.channels)
        guard header.channels > 0, payload >= 0, payload % bytesPerFrame == 0 else { throw DecodeError.badLength }
        let sampleCount = payload / header.format.bytesPerSample
        if out.count < sampleCount { out = [Float](repeating: 0, count: sampleCount) }
        data.withUnsafeBytes { raw in
            let base = AudioChunkHeader.size
            switch header.format {
            case .int16:
                for i in 0..<sampleCount {
                    let v = Int16(bitPattern: raw.loadLE(UInt16.self, at: base + i * 2))
                    out[i] = Float(v) / 32767
                }
            case .float32:
                for i in 0..<sampleCount {
                    out[i] = Float(bitPattern: raw.loadLE(UInt32.self, at: base + i * 4))
                }
            }
        }
        return payload / bytesPerFrame
    }
}

extension Data {
    @inlinable mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

extension UnsafeRawBufferPointer {
    @inlinable func loadLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
