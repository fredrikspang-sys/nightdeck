import Darwin
import Foundation

/// Browses `_musc._tcp`, `_musp._tcp` and `_musz._tcp`, and LSDP on UDP 11430, for a few seconds. musc results come first.
public final class PlayerDiscovery: @unchecked Sendable {
    private let lock = NSLock()
    private var box: BrowseBox?

    public init() {}

    public func browse(timeout: TimeInterval = 2) async -> [DiscoveredPlayer] {
        let limit = min(30, max(0.5, timeout))
        async let mdns = browseBonjour(timeout: limit)
        async let lsdp = LsdpDiscovery.browse(timeout: limit)
        return Self.merge(mdns: await mdns, lsdp: await lsdp)
    }

    static func merge(mdns: [DiscoveredPlayer], lsdp: [DiscoveredPlayer]) -> [DiscoveredPlayer] {
        var found: [DiscoveredPlayer] = []
        for player in mdns + lsdp {
            if !found.contains(where: { $0.host == player.host && $0.port == player.port }) {
                found.append(player)
            }
        }
        return found
    }

    private func browseBonjour(timeout: TimeInterval) async -> [DiscoveredPlayer] {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [self] in
                let next = BrowseBox()
                self.lock.lock()
                let previous = self.box
                self.box = next
                self.lock.unlock()
                previous?.cancel()
                next.start(timeout: timeout, continuation: continuation)
            }
        }
    }
}

private final class BrowseBox: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
    private let types = ["_musc._tcp.", "_musp._tcp.", "_musz._tcp."]
    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var found: [DiscoveredPlayer] = []
    private var continuation: CheckedContinuation<[DiscoveredPlayer], Never>?
    private var resumed = false

    func start(timeout: TimeInterval, continuation: CheckedContinuation<[DiscoveredPlayer], Never>) {
        self.continuation = continuation
        for type in types {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            browser.searchForServices(ofType: type, inDomain: "local.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish()
        }
    }

    func cancel() { finish() }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        services.append(service)
        service.resolve(withTimeout: 1.5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var host = ipv4(sender) ?? sender.hostName ?? ""
        host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return }
        let port = sender.port > 0 ? sender.port : NightdeckDefaults.port
        let player = DiscoveredPlayer(name: sender.name, host: host, port: port, serviceType: sender.type)
        if !found.contains(where: { $0.host == player.host && $0.port == player.port }) {
            found.append(player)
        }
    }

    private func finish() {
        guard !resumed else { return }
        resumed = true
        let pendingBrowsers = browsers
        let pendingServices = services
        browsers.removeAll()
        services.removeAll()
        for browser in pendingBrowsers {
            browser.delegate = nil
            browser.stop()
        }
        for service in pendingServices {
            service.delegate = nil
            service.stop()
        }
        let order = types
        let sorted = found.sorted { a, b in
            let ia = order.firstIndex(of: a.serviceType) ?? 9
            let ib = order.firstIndex(of: b.serviceType) ?? 9
            if ia != ib { return ia < ib }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        let pending = continuation
        continuation = nil
        pending?.resume(returning: sorted)
    }

    /// First routable IPv4. Skips loopback. Link-local is used only when nothing else resolved.
    private func ipv4(_ service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        let size = MemoryLayout<sockaddr_in>.size
        var linkLocal: String?
        for data in addresses {
            guard data.count >= size else { continue }
            var addr = sockaddr_in()
            let copied = withUnsafeMutableBytes(of: &addr) { data.copyBytes(to: $0) }
            guard copied >= size, addr.sin_family == sa_family_t(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let host = String(decoding: bytes, as: UTF8.self)
            if host.isEmpty || host == "0.0.0.0" || host.hasPrefix("127.") { continue }
            if host.hasPrefix("169.254.") {
                if linkLocal == nil { linkLocal = host }
                continue
            }
            return host
        }
        return linkLocal
    }
}
