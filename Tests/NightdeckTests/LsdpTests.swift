import Foundation
import Testing
@testable import NightdeckCore

@Suite struct LsdpTests {
    // Captured announce for a C388 named SEALPLAYER (API port 11000, plus a testing record).
    static let sealplayer: [UInt8] = [
        0x06, 0x4C, 0x53, 0x44, 0x50, 0x01, 0x6A, 0x41, 0x06, 0x90, 0x56, 0x82, 0x0E, 0x1B,
        0x00, 0x04, 0x0A, 0x00, 0x01, 0x24, 0x02, 0x00, 0x01, 0x05, 0x04, 0x6E, 0x61, 0x6D,
        0x65, 0x0A, 0x53, 0x45, 0x41, 0x4C, 0x50, 0x4C, 0x41, 0x59, 0x45, 0x52, 0x04, 0x70,
        0x6F, 0x72, 0x74, 0x05, 0x31, 0x31, 0x30, 0x30, 0x30, 0x05, 0x6D, 0x6F, 0x64, 0x65,
        0x6C, 0x04, 0x43, 0x33, 0x38, 0x38, 0x07, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6F, 0x6E,
        0x06, 0x33, 0x2E, 0x31, 0x36, 0x2E, 0x35, 0x02, 0x7A, 0x73, 0x01, 0x30, 0x00, 0x04,
        0x02, 0x04, 0x6E, 0x61, 0x6D, 0x65, 0x0A, 0x53, 0x45, 0x41, 0x4C, 0x50, 0x4C, 0x41,
        0x59, 0x45, 0x52, 0x04, 0x70, 0x6F, 0x72, 0x74, 0x05, 0x31, 0x31, 0x34, 0x33, 0x31,
    ]

    @Test func queryPacketIsVersionOneQueryAll() {
        let q = Array(LsdpDiscovery.queryPacket())
        #expect(q == [0x06, 0x4C, 0x53, 0x44, 0x50, 0x01, 0x05, 0x51, 0x01, 0xFF, 0xFF])
    }

    @Test func parseRejectsJunk() {
        #expect(LsdpDiscovery.parse([], source: "192.0.2.1") == nil)
        #expect(LsdpDiscovery.parse([0x00], source: "192.0.2.1") == nil)
        #expect(LsdpDiscovery.parse([0x06, 0x4D, 0x53, 0x44, 0x50, 0x01, 0x05, 0x51, 0x01, 0xFF, 0xFF], source: "192.0.2.1") == nil)
        #expect(LsdpDiscovery.parse([0x06, 0x4C, 0x53, 0x44, 0x50, 0x02, 0x05, 0x51, 0x01, 0xFF, 0xFF], source: "192.0.2.1") == nil)
        #expect(LsdpDiscovery.parse([0x06, 0x4C, 0x53, 0x44, 0x50, 0x01, 0x05, 0x51, 0x01, 0xFF, 0xFF], source: "192.0.2.1") == nil)
    }

    @Test func parseCapturedAnnounce() {
        let player = LsdpDiscovery.parse(Self.sealplayer, source: "198.51.100.9")
        #expect(player?.name == "SEALPLAYER")
        #expect(player?.host == "10.0.1.36")
        #expect(player?.port == 11000)
        #expect(player?.serviceType == "lsdp")
    }

    @Test func parseUsesSourceWhenAddressIsZero() {
        // Same as SEALPLAYER but IPv4 octets set to 0.0.0.0
        var bytes = Self.sealplayer
        bytes[16] = 0; bytes[17] = 0; bytes[18] = 0; bytes[19] = 0
        let player = LsdpDiscovery.parse(bytes, source: "198.51.100.9")
        #expect(player?.host == "198.51.100.9")
        #expect(player?.name == "SEALPLAYER")
    }

    @Test func parseIgnoresTestingOnlyAnnounce() {
        // Header + announce, node id 1 byte, IPv4 192.0.2.10, one Testing record with port 11431
        let bytes: [UInt8] = [
            0x06, 0x4C, 0x53, 0x44, 0x50, 0x01,
            0x20, 0x41,
            0x01, 0xAA,
            0x04, 192, 0, 2, 10,
            0x01,
            0x00, 0x04,
            0x02,
            0x04, 0x6E, 0x61, 0x6D, 0x65, 0x01, 0x58,
            0x04, 0x70, 0x6F, 0x72, 0x74, 0x05, 0x31, 0x31, 0x34, 0x33, 0x31,
        ]
        #expect(LsdpDiscovery.parse(bytes, source: "192.0.2.1") == nil)
    }

    @Test func zeroTimeoutSkipsTheNetwork() async {
        let found = await LsdpDiscovery.browse(timeout: 0)
        #expect(found.isEmpty)
    }

    @Test func unicastResponder() async throws {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        #expect(sock >= 0)
        defer { close(sock) }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
        var got = sockaddr_in()
        var glen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &got) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &glen)
            }
        }
        #expect(named == 0)
        let port = Int(UInt16(bigEndian: got.sin_port))

        let reply = Self.sealplayer
        let server = Task.detached {
            var buf = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
            var pf = pollfd(fd: sock, events: Int16(POLLIN), revents: 0)
            guard poll(&pf, 1, 3000) > 0 else { return false }
            let n = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(sock, &buf, buf.count, 0, $0, &flen)
                }
            }
            guard n >= 11, buf[1] == 0x4C, buf[7] == 0x51 else { return false }
            _ = withUnsafePointer(to: &from) { ptr in
                reply.withUnsafeBufferPointer { payload in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(sock, payload.baseAddress, reply.count, 0, $0, flen)
                    }
                }
            }
            return true
        }

        let old = ProcessInfo.processInfo.environment["NIGHTDECK_LSDP_ADDR"]
        setenv("NIGHTDECK_LSDP_ADDR", "127.0.0.1:\(port)", 1)
        let found = await LsdpDiscovery.browse(timeout: 0.8)
        if let old { setenv("NIGHTDECK_LSDP_ADDR", old, 1) } else { unsetenv("NIGHTDECK_LSDP_ADDR") }

        #expect(await server.value)
        #expect(found.count == 1)
        #expect(found.first?.name == "SEALPLAYER")
        #expect(found.first?.host == "10.0.1.36")
        #expect(found.first?.port == 11000)
    }

    @Test func mergeKeepsMdnsFirstAndDropsDuplicateHostPort() {
        let musc = DiscoveredPlayer(name: "Den", host: "192.0.2.10", port: 11000, serviceType: "_musc._tcp.")
        let extra = DiscoveredPlayer(name: "Hall", host: "192.0.2.11", port: 11000, serviceType: "lsdp")
        let dup = DiscoveredPlayer(name: "Other", host: "192.0.2.10", port: 11000, serviceType: "lsdp")
        let merged = PlayerDiscovery.merge(mdns: [musc], lsdp: [dup, extra])
        #expect(merged.count == 2)
        #expect(merged[0].name == "Den")
        #expect(merged[0].serviceType == "_musc._tcp.")
        #expect(merged[1].name == "Hall")
    }
}
