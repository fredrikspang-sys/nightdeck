import Foundation

/// Sleep-at-zero, matching bluplay 0.3.1: 3 s grace, 16 volume steps, then pause or stop, then restore.
public struct SleepFadeConfig: Sendable, Equatable {
    public var enabled: Bool
    public var seconds: Double
    public var endWithStop: Bool

    public init(enabled: Bool = true, seconds: Double = 24, endWithStop: Bool = false) {
        self.enabled = enabled
        self.seconds = seconds
        self.endWithStop = endWithStop
    }

    public var clampedSeconds: Double { min(300, max(2, seconds)) }
}

public enum SleepFadeEvent: Sendable, Equatable {
    case fading
    case paused(restored: Bool)
    case stopped(restored: Bool)
    case cancelled(restored: Bool)
    case failed(String)
}

public enum SleepFadeAction: Sendable, Equatable {
    case setVolume(Int)
    case pause
    case stop
    case notify(SleepFadeEvent)
}

public struct SleepFade: Sendable {
    public private(set) var config: SleepFadeConfig
    public var isActive: Bool { phase != .idle }
    public var caption: String? {
        switch phase {
        case .grace: return "Sleep ending…"
        case .fading: return "Fading…"
        case .idle, .waiting: return nil
        }
    }

    private enum Phase: Equatable { case idle, grace, fading, waiting }
    private enum Hold: Equatable { case off, all, until(Int) }
    private var phase: Phase = .idle
    private var hold: Hold = .off
    private var prevSleep = 0
    private var havePrev = false
    private var origVolume = -1
    private var lastVolume = -1
    private var step = 0
    private var deadline: Date?
    private var nextStep: Date?

    private static let grace: TimeInterval = 3
    private static let steps = 16
    private static let pauseWait: TimeInterval = 10

    public init(config: SleepFadeConfig = SleepFadeConfig()) {
        self.config = config
    }

    public mutating func updateConfig(_ config: SleepFadeConfig) {
        self.config = config
    }

    /// Ignore countdown edges until `noteCommanded` (a `/Sleep` is in flight).
    public mutating func beginCommand() {
        hold = .all
    }

    /// Call after a successful `/Sleep`. A status that still shows the old minutes must not look like expiry.
    public mutating func noteCommanded(minutes: Int) {
        prevSleep = minutes
        havePrev = true
        hold = .until(minutes)
        if phase == .grace {
            phase = .idle
            deadline = nil
        }
    }

    public mutating func endCommand() {
        hold = .off
    }

    /// True when the next decision needs a fresh `/Status` before any volume or transport write.
    public func needsConfirm(status: PlayerStatus, now: Date) -> Bool {
        switch phase {
        case .grace:
            guard status.sleepMinutes == 0, status.state.isPlaying, let deadline else { return false }
            return now >= deadline
        case .waiting:
            guard status.state.isPlaying, let deadline else { return false }
            return now >= deadline
        case .idle, .fading:
            return false
        }
    }

    public mutating func abort(restoreVolume: Bool = true) -> [SleepFadeAction] {
        guard phase != .idle else { return [] }
        let restore = restoreVolume && lowered
        phase = .idle
        deadline = nil
        nextStep = nil
        lastVolume = -1
        var actions: [SleepFadeAction] = []
        if restore { actions.append(.setVolume(origVolume)) }
        actions.append(.notify(.cancelled(restored: restore)))
        origVolume = -1
        step = 0
        return actions
    }

    public mutating func tick(
        status: PlayerStatus,
        now: Date,
        confirmed: Bool = true
    ) -> (actions: [SleepFadeAction], nextWake: Date?) {
        if phase == .idle || phase == .grace, holding(status) {
            if phase == .grace {
                phase = .idle
                deadline = nil
            }
            return ([], nil)
        }
        switch phase {
        case .idle:
            if havePrev, status.sleepMinutes == 0, prevSleep > 0, prevSleep <= 2, status.state.isPlaying {
                phase = .grace
                deadline = now.addingTimeInterval(Self.grace)
            }
            prevSleep = status.sleepMinutes
            havePrev = true
            return ([], phase == .grace ? deadline : nil)
        case .grace:
            prevSleep = status.sleepMinutes
            if status.sleepMinutes > 0 || !status.state.isPlaying {
                phase = .idle
                deadline = nil
                return ([], nil)
            }
            if let deadline, now >= deadline {
                if !confirmed { return ([], deadline) }
                return begin(status: status, now: now)
            }
            return ([], deadline)
        case .fading:
            prevSleep = status.sleepMinutes
            if !status.state.isPlaying {
                if !confirmed { return ([], now) }
                return finish(failed: false)
            }
            guard let nextStep, now >= nextStep else { return ([], nextStep) }
            if !confirmed { return ([], nextStep) }
            return advance(now: now)
        case .waiting:
            prevSleep = status.sleepMinutes
            if !status.state.isPlaying { return finish(failed: false) }
            if let deadline, now >= deadline {
                if !confirmed { return ([], deadline) }
                return finish(failed: true)
            }
            return ([], deadline)
        }
    }

    private mutating func holding(_ status: PlayerStatus) -> Bool {
        switch hold {
        case .off:
            return false
        case .all:
            return true
        case .until(let minutes):
            if status.sleepMinutes == minutes {
                hold = .off
                return false
            }
            return true
        }
    }

    private var lowered: Bool { origVolume > 0 && lastVolume >= 0 && lastVolume < origVolume }

    private mutating func begin(status: PlayerStatus, now: Date) -> (actions: [SleepFadeAction], nextWake: Date?) {
        guard status.state.isPlaying else {
            phase = .idle
            deadline = nil
            return ([], nil)
        }
        let canFade = config.enabled && !status.mute && status.volume > 0
        if !canFade {
            origVolume = -1
            lastVolume = -1
            phase = .waiting
            deadline = now.addingTimeInterval(Self.pauseWait)
            nextStep = nil
            return ([config.endWithStop ? .stop : .pause], deadline)
        }
        origVolume = status.volume
        lastVolume = status.volume
        step = 0
        phase = .fading
        nextStep = now
        return advance(now: now)
    }

    private mutating func advance(now: Date) -> (actions: [SleepFadeAction], nextWake: Date?) {
        step += 1
        let target = max(0, origVolume * (Self.steps - step) / Self.steps)
        var actions: [SleepFadeAction] = []
        if target < lastVolume {
            actions.append(.setVolume(target))
            lastVolume = target
        }
        if step == 1 { actions.append(.notify(.fading)) }
        if step >= Self.steps {
            phase = .waiting
            nextStep = nil
            deadline = now.addingTimeInterval(Self.pauseWait)
            actions.append(config.endWithStop ? .stop : .pause)
            return (actions, deadline)
        }
        let interval = config.clampedSeconds / Double(Self.steps)
        nextStep = now.addingTimeInterval(interval)
        return (actions, nextStep)
    }

    private mutating func finish(failed: Bool) -> (actions: [SleepFadeAction], nextWake: Date?) {
        let restore = lowered
        var actions: [SleepFadeAction] = []
        if restore { actions.append(.setVolume(origVolume)) }
        if failed {
            let what = config.endWithStop ? "stop" : "pause"
            actions.append(.notify(.failed("Sleep: the \(what) did not take effect")))
        } else if config.endWithStop {
            actions.append(.notify(.stopped(restored: restore)))
        } else {
            actions.append(.notify(.paused(restored: restore)))
        }
        phase = .idle
        deadline = nil
        nextStep = nil
        lastVolume = -1
        origVolume = -1
        step = 0
        return (actions, nil)
    }
}
