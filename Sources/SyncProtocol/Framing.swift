import Foundation

/// Leader↔follower TCP link: `[UInt32 BE length][UInt8 type][payload]`, where length counts type + payload.
public enum LinkFrame {
    public enum FrameType: UInt8, Sendable {
        case control = 1 // JSON ControlMessage
        case audio = 2   // AudioChunkHeader + samples
    }

    public static let prefixSize = 4
    public static let maxLength = 8 * 1024 * 1024

    public static func encode(_ type: FrameType, payload: Data) -> Data {
        var data = Data(capacity: prefixSize + 1 + payload.count)
        let length = UInt32(payload.count + 1).bigEndian
        withUnsafeBytes(of: length) { data.append(contentsOf: $0) }
        data.append(type.rawValue)
        data.append(payload)
        return data
    }

    public static func length(fromPrefix prefix: Data) -> Int? {
        guard prefix.count == prefixSize else { return nil }
        let length = prefix.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        return (1...maxLength).contains(length) ? length : nil
    }

    public static func encodeControl(_ message: ControlMessage) throws -> Data {
        encode(.control, payload: try JSONEncoder().encode(message))
    }
}
