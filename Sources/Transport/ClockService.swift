import ClockSync
import Foundation
import SyncProtocol

/// Leader: answers clock pings on a dedicated thread with blocking BSD sockets (lowest stamping latency).
public final class ClockServer: @unchecked Sendable {
    private var thread: Thread?

    public init() {}

    public func start(port: UInt16 = SyncConstants.clockPort) throws {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var off: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size)) // accept IPv4 too
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno) ?? .EADDRINUSE)
        }
        // Wake up periodically so cancellation is noticed; the thread owns and closes the socket.
        var wake = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wake, socklen_t(MemoryLayout<timeval>.size))
        let thread = Thread {
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: 128)
            var from = sockaddr_storage()
            while !Thread.current.isCancelled {
                var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = buffer.withUnsafeMutableBytes { raw in
                    withUnsafeMutablePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen) }
                    }
                }
                let t2 = HostClock.nowNs()
                guard n >= ClockPacket.size else { continue }
                guard var packet = buffer.withUnsafeBytes({ ClockPacket(bytes: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }),
                      packet.kind == .ping else { continue }
                packet.kind = .pong
                packet.t2 = t2
                packet.t3 = HostClock.nowNs()
                let reply = packet.encoded()
                _ = reply.withUnsafeBytes { raw in
                    withUnsafePointer(to: &from) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, raw.baseAddress, raw.count, 0, $0, fromLen) }
                    }
                }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "syncspeaker.clock.server"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        thread?.cancel()
        thread = nil
    }
}

/// Follower: pings the leader 10×/s and publishes an updated cluster clock map.
public final class ClockClient: @unchecked Sendable {
    public var onUpdate: (@Sendable (ClockMap, ClockEstimator.Stats) -> Void)?

    private let lock = NSLock()
    private var estimator = ClockEstimator()
    private var thread: Thread?

    public init() {}

    public var stats: ClockEstimator.Stats { lock.withLock { estimator.stats } }
    public var map: ClockMap? { lock.withLock { estimator.map } }

    public func start(host: String, port: UInt16 = SyncConstants.clockPort) {
        stop()
        lock.withLock { estimator.reset() }
        let thread = Thread { [weak self] in self?.run(host: host, port: port) }
        thread.qualityOfService = .userInteractive
        thread.name = "syncspeaker.clock.client"
        thread.start()
        self.thread = thread
    }

    public func stop() {
        thread?.cancel()
        thread = nil
    }

    private func run(host: String, port: UInt16) {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let info = result else { return }
        defer { freeaddrinfo(result) }

        let fd = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { return }
        var timeout = timeval(tv_sec: 0, tv_usec: 90_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var seq: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 128)
        while !Thread.current.isCancelled {
            seq += 1
            let started = HostClock.nowNs()
            let ping = ClockPacket(kind: .ping, seq: seq, t1: HostClock.nowNs()).encoded()
            _ = ping.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

            // Wait for the matching pong; stale pongs from earlier pings are skipped.
            while HostClock.nowNs() - started < 95_000_000 {
                let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                let t4 = HostClock.nowNs()
                guard n >= ClockPacket.size else { break }
                guard let pong = buffer.withUnsafeBytes({ ClockPacket(bytes: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }),
                      pong.kind == .pong, pong.seq == seq else { continue }
                let exchange = ClockEstimator.Exchange(t1: pong.t1, t2: pong.t2, t3: pong.t3, t4: t4)
                let update = lock.withLock { () -> (ClockMap, ClockEstimator.Stats)? in
                    guard estimator.add(exchange), let map = estimator.map else { return nil }
                    return (map, estimator.stats)
                }
                if let update { onUpdate?(update.0, update.1) }
                break
            }
            let elapsed = HostClock.nowNs() - started
            if elapsed < 100_000_000 { usleep(useconds_t((100_000_000 - elapsed) / 1_000)) }
        }
    }
}
