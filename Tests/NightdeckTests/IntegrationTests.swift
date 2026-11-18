import Foundation
import Testing
@testable import NightdeckCore

@Test func statusPollerEmitsTheNewState() async throws {
    let mock = try await MockServer.launch()
    defer { mock.stop() }
    let poller = StatusPoller(client: mock.client())
    let stream = poller.events()
    let collect = Task { () -> [PlaybackState] in
        var states: [PlaybackState] = []
        for await event in stream {
            if case .status(let status) = event {
                states.append(status.state)
                if states.contains(.pause) { break }
            }
            if states.count > 8 { break }
        }
        return states
    }
    try await Task.sleep(nanoseconds: 250_000_000)
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(mock.port)/_x?state=pause")!)
    request.timeoutInterval = 2
    _ = try await URLSession.shared.data(for: request)
    let states = await firstResult(collect, seconds: 8)
    collect.cancel()
    #expect(states.contains(.play))
    #expect(states.contains(.pause))
}

private func firstResult(_ task: Task<[PlaybackState], Never>, seconds: Double) async -> [PlaybackState] {
    await withTaskGroup(of: [PlaybackState].self) { group in
        group.addTask { await task.value }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return []
        }
        let value = await group.next() ?? []
        group.cancelAll()
        return value
    }
}
