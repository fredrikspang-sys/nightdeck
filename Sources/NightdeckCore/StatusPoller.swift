import Foundation

public struct PollFailure: Sendable {
    public var message: String
    public var network: Bool

    public init(message: String, network: Bool) {
        self.message = message
        self.network = network
    }
}

public enum PollEvent: Sendable {
    case status(PlayerStatus)
    case failure(PollFailure)
}

/// Long-polls `/Status`. One request at a time. Backs off when the player is down or ignores etag.
public struct StatusPoller: Sendable {
    public let client: any BluOSClient

    public init(client: any BluOSClient) {
        self.client = client
    }

    public func events() -> AsyncStream<PollEvent> {
        let client = self.client
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let task = Task {
                var etag: String?
                var errors = 0
                while !Task.isCancelled {
                    let started = Date()
                    let longPoll = !(etag ?? "").isEmpty
                    do {
                        let status = try await client.status(
                            timeout: longPoll ? NightdeckDefaults.statusLongPollSeconds : nil,
                            etag: etag
                        )
                        if Task.isCancelled { break }
                        let elapsed = Date().timeIntervalSince(started)
                        var gap: TimeInterval = 1
                        if status.etag.isEmpty || (longPoll && status.etag == etag && elapsed < 30) {
                            gap = 5
                        }
                        gap = max(0, gap - elapsed)
                        etag = status.etag.isEmpty ? nil : status.etag
                        errors = 0
                        if case .terminated = continuation.yield(.status(status)) { break }
                        if gap > 0 {
                            try await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000))
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        etag = nil
                        errors += 1
                        let failure = PollFailure(
                            message: PlayerMessages.describe(error, host: ""),
                            network: PlayerMessages.isNetwork(error)
                        )
                        if case .terminated = continuation.yield(.failure(failure)) { break }
                        let shift = min(max(errors - 1, 0), 2)
                        let backoff = min(4.0, Double(1 << shift))
                        do {
                            try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                        } catch {
                            break
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
