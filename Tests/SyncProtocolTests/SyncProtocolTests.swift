import Foundation
import Testing
@testable import SyncProtocol

@Suite struct SyncProtocolTests {
    @Test func audioChunkRoundTrip() throws {
        let header = AudioChunkHeader(channels: 2, format: .int16, sampleRate: 48_000, epoch: 7,
                                      frameIndex: 123_456_789, ptsNs: -42, nsPerFrame: 20833.3335)
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 2]
        let data = samples.withUnsafeBufferPointer { AudioChunkCodec.encode(header: header, samples: $0) }
        #expect(data.count == AudioChunkHeader.size + samples.count * 2)
        #expect(try AudioChunkCodec.decodeHeader(data) == header)
        var out = [Float]()
        let frames = try AudioChunkCodec.decodeSamples(data, header: header, into: &out)
        #expect(frames == 3)
        #expect(abs(out[1] - 0.5) < 1e-4 && out[5] == 1) // clipped
    }

    @Test func clockPacketRoundTrip() throws {
        let packet = ClockPacket(kind: .pong, seq: 99, t1: 1, t2: -2, t3: Int64.max)
        let bytes = packet.encoded()
        let decoded = try #require(bytes.withUnsafeBytes { ClockPacket(bytes: $0) })
        #expect(decoded == packet)
    }

    @Test func controlMessagesUseReadableJSON() throws {
        let command = ControlMessage.calibrate(CalibrationCommand(
            id: 3, recordStartClusterNs: 10, recordSeconds: 1.2, chirpStartClusterNs: [.a: 100, .b: 200]))
        let json = String(decoding: try JSONEncoder().encode(command), as: UTF8.self)
        #expect(json.contains("\"A\":100"))
        #expect(try JSONDecoder().decode(ControlMessage.self, from: Data(json.utf8)) == command)
    }

    @Test func linkFramePrefix() throws {
        let frame = LinkFrame.encode(.audio, payload: Data([1, 2, 3]))
        #expect(LinkFrame.length(fromPrefix: frame.prefix(4)) == 4)
        #expect(frame[4] == LinkFrame.FrameType.audio.rawValue)
    }

    @Test func phoneMessageShape() throws {
        let json = #"{"pose":{"_0":{"position":[1,0,2],"forward":[0,-1],"tracking":"normal"}}}"#
        let message = try JSONDecoder().decode(PhoneMessage.self, from: Data(json.utf8))
        #expect(message == .pose(ListenerPose(position: [1, 0, 2], forward: [0, -1], tracking: .normal)))
    }
}
