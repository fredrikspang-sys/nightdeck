import Darwin
import Foundation

/// Lenbrook Service Discovery Protocol (UDP port 11430).
/// A query is broadcast on every usable IPv4 interface; announce replies name the player and API port.
/// When NIGHTDECK_LSDP_ADDR is set to host:port, the query is sent only there (test hook).
public enum LsdpDiscovery: Sendable {
    public static let port = 11430

    private static let query: [UInt8] = [
        0x06, 0x4C, 0x53, 0x44, 0x50, 0x01,
        0x05, 0x51, 0x01, 0xFF, 0xFF,
    ]

    public static func queryPacket() -> Data { Data(query) }

    /// Parses an announce. Queries, deletes, and malformed packets return nil.
    public static func parse(_ data: Data, source: String) -> DiscoveredPlayer? {
        parse(Array(data), source: source)
    }

    public static func parse(_ bytes: [UInt8], source: String) -> DiscoveredPlayer? {
        var off = 0
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard off + n <= bytes.count else { return nil }
            let slice = bytes[off..<(off + n)]
            off += n
            return slice
        }
        func u8() -> UInt8? { take(1)?.first }
        func lenPrefixed() -> ArraySlice<UInt8>? {
            guard let len = u8() else { return nil }
            return take(Int(len))
        }

        guard let headerLen = u8(), headerLen == 6 else { return nil }
        guard let magic = take(4), Array(magic) == [0x4C, 0x53, 0x44, 0x50] else { return nil }
        guard let version = u8(), version == 1 else { return nil }
        guard u8() != nil, let type = u8(), type == 0x41 else { return nil }
        guard lenPrefixed() != nil, let ipBytes = lenPrefixed() else { return nil }

        var host = ""
        if ipBytes.count == 4 {
            let b = Array(ipBytes)
            if b.contains(where: { $0 != 0 }) {
                host = "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
            }
        }
        if host.isEmpty { host = source }
        guard !host.isEmpty else { return nil }

        guard let recCount = u8() else { return nil }
        var name = ""
        var port = 0
        var physical = false
        for _ in 0..<recCount {
            guard let classBytes = take(2) else { return nil }
            let cls = (UInt16(classBytes[classBytes.startIndex]) << 8) | UInt16(classBytes[classBytes.startIndex + 1])
            let isPhysical = cls == 1 || cls == 2 || cls == 3 || cls == 6 || cls == 8
            guard let fields = u8() else { return nil }
            var recName = ""
            var recPort = 0
            for _ in 0..<fields {
                guard let key = lenPrefixed(), let val = lenPrefixed() else { return nil }
                let k = String(bytes: key, encoding: .utf8) ?? ""
                let v = String(bytes: val, encoding: .utf8) ?? ""
                if k == "name", recName.isEmpty { recName = v }
                if k == "port", recPort == 0, let p = Int(v), (1...65535).contains(p) { recPort = p }
            }
            if isPhysical {
                physical = true
                if name.isEmpty { name = recName }
                if port == 0 { port = recPort }
            }
        }
        guard physical else { return nil }
        if name.isEmpty { name = host }
        if port == 0 { port = NightdeckDefaults.port }
        return DiscoveredPlayer(name: name, host: host, port: port, serviceType: "lsdp")
    }

    public static func browse(timeout: TimeInterval) async -> [DiscoveredPlayer] {
        let limit = min(30, max(0, timeout))
        if limit <= 0 { return [] }
        return await Task {
            discover(timeout: limit)
        }.value
    }

    static func discover(timeout: TimeInterval) -> [DiscoveredPlayer] {
        var found: [DiscoveredPlayer] = []
        func add(_ player: DiscoveredPlayer) {
            if !found.contains(where: { $0.host == player.host && $0.port == player.port }) {
                found.append(player)
            }
        }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        func bindPort(_ port: UInt16) -> Bool {
            var bindAddr = sockaddr_in()
            bindAddr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            bindAddr.sin_family = sa_family_t(AF_INET)
            bindAddr.sin_port = in_port_t(port.bigEndian)
            bindAddr.sin_addr = in_addr(s_addr: INADDR_ANY)
            return withUnsafePointer(to: &bindAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            } == 0
        }
        // Players answer on UDP 11430, not the ephemeral source port.
        guard bindPort(UInt16(port)) || bindPort(0) else { return [] }

        let dests = destinations()
        guard !dests.isEmpty else { return [] }
        let packet = Array(queryPacket())
        let t0 = Date()
        var sent = 0
        var pf = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)

        while Date().timeIntervalSince(t0) < timeout {
            if Task.isCancelled { break }
            let elapsed = Date().timeIntervalSince(t0)
            if sent == 0 || (sent == 1 && elapsed >= 0.3) || (sent == 2 && elapsed >= 1.0) {
                for dest in dests {
                    var addr = dest
                    _ = withUnsafePointer(to: &addr) { ptr in
                        packet.withUnsafeBufferPointer { buf in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, buf.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                }
                sent += 1
            }
            var next = timeout
            if sent == 1 { next = min(next, 0.3) }
            else if sent == 2 { next = min(next, 1.0) }
            let wait = max(0.001, min(next - elapsed, 0.25))
            pf.revents = 0
            let ready = poll(&pf, 1, Int32(wait * 1000))
            guard ready > 0 else { continue }
            var buf = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buf, buf.count, 0, $0, &flen)
                }
            }
            guard n > 0 else { continue }
            var src = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = inet_ntop(AF_INET, &from.sin_addr, &src, socklen_t(INET_ADDRSTRLEN))
            let source = String(decoding: src.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let player = parse(Array(buf.prefix(Int(n))), source: source) {
                add(player)
            }
        }
        return found
    }

    static func destinations() -> [sockaddr_in] {
        if let hook = hookDestination() { return [hook] }
        var list: [sockaddr_in] = []
        var seen = Set<UInt32>()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return list }
        defer { freeifaddrs(first) }
        var cursor = ifap
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0, (flags & IFF_BROADCAST) != 0 else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let host = UInt32(bigEndian: ip)
            let b0 = UInt8((host >> 24) & 0xFF)
            let b1 = UInt8((host >> 16) & 0xFF)
            if b0 == 169 && b1 == 254 { continue }
            if b0 == 0 || b0 >= 224 { continue }
            guard let broad = ifa.ifa_dstaddr, broad.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var dest = broad.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            let key = dest.sin_addr.s_addr
            if seen.contains(key) { continue }
            seen.insert(key)
            dest.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = in_port_t(UInt16(port).bigEndian)
            list.append(dest)
            if list.count >= 16 { break }
        }
        return list
    }

    static func hookDestination() -> sockaddr_in? {
        guard let ov = ProcessInfo.processInfo.environment["NIGHTDECK_LSDP_ADDR"], !ov.isEmpty else { return nil }
        guard let colon = ov.lastIndex(of: ":") else { return nil }
        let host = String(ov[..<colon]).trimmingCharacters(in: .whitespaces)
        let portText = String(ov[ov.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard let p = UInt16(portText), p > 0 else { return nil }
        var addr = in_addr()
        guard inet_pton(AF_INET, host, &addr) == 1 else { return nil }
        var dest = sockaddr_in()
        dest.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(p.bigEndian)
        dest.sin_addr = addr
        return dest
    }
}
