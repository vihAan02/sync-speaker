import AudioIO
import Foundation

/// Milestone-1 spike: proves the global tap hears AirPlay/Music.app audio and mutes the speakers.
enum CaptureTest {
    static func run(seconds: Double, path: String) throws {
        let tap = SystemAudioTap()
        try tap.start(mute: true)
        defer { tap.stop() }
        let rate = tap.sampleRate
        print("Capturing \(seconds) s at \(rate) Hz → \(path). Play something (AirPlay to this Mac, or Music.app).")

        var samples: [Float] = []
        samples.reserveCapacity(Int(seconds * rate) * 2)
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: tap.maxBlockFrames * 2)
        defer { buffer.deallocate() }
        var peak: Float = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let block = tap.pop(into: buffer, capacityFrames: tap.maxBlockFrames) {
                let chunk = UnsafeBufferPointer(start: buffer, count: block.frames * 2)
                samples.append(contentsOf: chunk)
                peak = max(peak, chunk.map(abs).max() ?? 0)
            } else {
                usleep(2_000)
            }
        }
        try WAVWriter.write(interleavedStereo: samples, sampleRate: rate, to: URL(fileURLWithPath: path))
        let peakDb = peak > 0 ? 20 * log10(peak) : -120
        print(String(format: "Wrote %.1f s, peak %.1f dBFS, dropped blocks: %lld", Double(samples.count / 2) / rate, peakDb, tap.droppedBlocks))
        if peak == 0 { print("Warning: silence captured. Check System Settings › Privacy & Security › System Audio Recording.") }
    }
}

enum WAVWriter {
    static func write(interleavedStereo samples: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(2); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * 4); u16(4); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        try data.write(to: url)
    }
}
