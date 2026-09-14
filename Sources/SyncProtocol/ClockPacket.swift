import Foundation

/// NTP-style exchange. The follower stamps t1 on send and t4 on receive; the leader stamps t2/t3.
public struct ClockPacket: Equatable, Sendable {
    public static let magic: UInt32 = 0x5353_434B // "SSCK"
    public static let size = 40

    public enum Kind: UInt32, Sendable { case ping = 1, pong = 2 }

    public var kind: Kind
    public var seq: UInt64
    public var t1: Int64
    public var t2: Int64
    public var t3: Int64

    public init(kind: Kind, seq: UInt64, t1: Int64, t2: Int64 = 0, t3: Int64 = 0) {
        self.kind = kind
        self.seq = seq
        self.t1 = t1
        self.t2 = t2
        self.t3 = t3
    }

    public func encoded() -> [UInt8] {
        var data = Data(capacity: Self.size)
        data.appendLE(Self.magic)
        data.appendLE(kind.rawValue)
        data.appendLE(seq)
        data.appendLE(UInt64(bitPattern: t1))
        data.appendLE(UInt64(bitPattern: t2))
        data.appendLE(UInt64(bitPattern: t3))
        return [UInt8](data)
    }

    public init?(bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= Self.size, bytes.loadLE(UInt32.self, at: 0) == Self.magic,
              let kind = Kind(rawValue: bytes.loadLE(UInt32.self, at: 4)) else { return nil }
        self.kind = kind
        seq = bytes.loadLE(UInt64.self, at: 8)
        t1 = Int64(bitPattern: bytes.loadLE(UInt64.self, at: 16))
        t2 = Int64(bitPattern: bytes.loadLE(UInt64.self, at: 24))
        t3 = Int64(bitPattern: bytes.loadLE(UInt64.self, at: 32))
    }
}
