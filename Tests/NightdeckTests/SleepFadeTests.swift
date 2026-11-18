import Foundation
import Testing
@testable import NightdeckCore

private func playing(volume: Int = 40, sleep: Int, mute: Bool = false) -> PlayerStatus {
    PlayerStatus(state: .play, volume: volume, mute: mute, sleepMinutes: sleep)
}

@Test func sleepFadeDoesNotTriggerWhenTurnedOffFromALongTimer() {
    var fade = SleepFade()
    let t0 = Date(timeIntervalSince1970: 1_000)
    _ = fade.tick(status: playing(sleep: 15), now: t0)
    let (actions, wake) = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(1))
    #expect(actions.isEmpty)
    #expect(wake == nil)
    #expect(fade.isActive == false)
}

@Test func sleepFadeGraceThenStepsThenPauseAndRestore() {
    var fade = SleepFade(config: SleepFadeConfig(enabled: true, seconds: 16, endWithStop: false))
    let t0 = Date(timeIntervalSince1970: 5_000)
    _ = fade.tick(status: playing(sleep: 2), now: t0)
    let entered = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(30))
    #expect(entered.actions.isEmpty)
    #expect(fade.isActive)
    let still = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(32))
    #expect(still.actions.isEmpty)
    let began = fade.tick(status: playing(volume: 32, sleep: 0), now: t0.addingTimeInterval(33))
    #expect(began.actions.contains(.setVolume(30)))
    #expect(began.actions.contains(.notify(.fading)))
    var now = t0.addingTimeInterval(33)
    var sawPause = false
    for _ in 0..<20 {
        guard let wake = fade.tick(status: playing(volume: 32, sleep: 0), now: now).1 ?? began.1 else { break }
        now = wake
        let step = fade.tick(status: playing(volume: 32, sleep: 0), now: now)
        if step.actions.contains(.pause) { sawPause = true; break }
    }
    #expect(sawPause)
    let done = fade.tick(status: PlayerStatus(state: .pause, volume: 0, sleepMinutes: 0), now: now.addingTimeInterval(1))
    #expect(done.actions.contains(.setVolume(32)))
    #expect(done.actions.contains(.notify(.paused(restored: true))))
    #expect(fade.isActive == false)
}

@Test func sleepWithoutFadePausesAndDoesNotTouchVolume() {
    var fade = SleepFade(config: SleepFadeConfig(enabled: false, seconds: 24, endWithStop: true))
    let t0 = Date(timeIntervalSince1970: 8_000)
    _ = fade.tick(status: playing(sleep: 1), now: t0)
    _ = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(1))
    let began = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(4))
    #expect(began.actions == [.stop])
    let done = fade.tick(status: PlayerStatus(state: .stop, volume: 40, sleepMinutes: 0), now: t0.addingTimeInterval(5))
    #expect(done.actions == [.notify(.stopped(restored: false))])
}

@Test func sleepCommandAndAbortDoNotLookLikeACountdownEnd() {
    var fade = SleepFade()
    let t0 = Date(timeIntervalSince1970: 9_000)
    _ = fade.tick(status: playing(sleep: 1), now: t0)
    fade.noteCommanded(minutes: 0)
    let (actions, _) = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(1))
    #expect(actions.isEmpty)
    #expect(fade.isActive == false)
    _ = fade.tick(status: playing(sleep: 2), now: t0.addingTimeInterval(2))
    _ = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(3))
    #expect(fade.isActive)
    let cancelled = fade.abort()
    #expect(cancelled.contains(.notify(.cancelled(restored: false))))
    #expect(fade.isActive == false)
}

@Test func sleepCommandIgnoresAStaleStatusThatStillShowsOneOrTwoMinutes() {
    var fade = SleepFade()
    let t0 = Date(timeIntervalSince1970: 11_000)
    _ = fade.tick(status: playing(sleep: 2), now: t0)
    fade.beginCommand()
    let during = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(1))
    #expect(during.actions.isEmpty)
    #expect(fade.isActive == false)
    fade.noteCommanded(minutes: 0)
    let stale = fade.tick(status: playing(sleep: 2), now: t0.addingTimeInterval(2))
    #expect(stale.actions.isEmpty)
    #expect(fade.isActive == false)
    let confirmed = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(3))
    #expect(confirmed.actions.isEmpty)
    #expect(fade.isActive == false)
    _ = fade.tick(status: playing(sleep: 1), now: t0.addingTimeInterval(4))
    _ = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(5))
    #expect(fade.isActive)
}

@Test func graceDoesNotFadeUntilTheStatusIsConfirmed() {
    var fade = SleepFade()
    let t0 = Date(timeIntervalSince1970: 12_000)
    _ = fade.tick(status: playing(sleep: 1), now: t0)
    _ = fade.tick(status: playing(sleep: 0), now: t0.addingTimeInterval(1))
    let due = t0.addingTimeInterval(4)
    #expect(fade.needsConfirm(status: playing(sleep: 0), now: due))
    let held = fade.tick(status: playing(volume: 40, sleep: 0), now: due, confirmed: false)
    #expect(held.actions.isEmpty)
    #expect(fade.isActive)
    let paused = fade.tick(status: PlayerStatus(state: .pause, volume: 40, sleepMinutes: 0), now: due)
    #expect(paused.actions.isEmpty)
    #expect(fade.isActive == false)
}

@Test func unconfirmedTickDoesNotAdvanceTheFade() {
    var fade = SleepFade(config: SleepFadeConfig(enabled: true, seconds: 16, endWithStop: false))
    let t0 = Date(timeIntervalSince1970: 13_000)
    _ = fade.tick(status: playing(sleep: 1), now: t0)
    _ = fade.tick(status: playing(volume: 32, sleep: 0), now: t0.addingTimeInterval(1))
    let due = t0.addingTimeInterval(4)
    let held = fade.tick(status: playing(volume: 32, sleep: 0), now: due, confirmed: false)
    #expect(held.actions.isEmpty)
    #expect(fade.isActive)
    let began = fade.tick(status: playing(volume: 32, sleep: 0), now: due)
    #expect(began.actions.contains(.setVolume(30)))
    let next = began.1 ?? due
    let stalled = fade.tick(status: playing(volume: 32, sleep: 0), now: next, confirmed: false)
    #expect(stalled.actions.isEmpty)
    #expect(fade.isActive)
}

@Test func mutedSleepSkipsTheFade() {
    var fade = SleepFade()
    let t0 = Date(timeIntervalSince1970: 10_000)
    _ = fade.tick(status: playing(volume: 40, sleep: 2, mute: true), now: t0)
    _ = fade.tick(status: playing(volume: 40, sleep: 0, mute: true), now: t0.addingTimeInterval(1))
    let began = fade.tick(status: playing(volume: 40, sleep: 0, mute: true), now: t0.addingTimeInterval(5))
    #expect(began.actions == [.pause])
}
