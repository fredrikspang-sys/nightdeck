import AppKit
import Foundation
import Network
import Observation
import NightdeckCore

@MainActor
@Observable
final class AppModel {
    private(set) var status = PlayerStatus()
    private(set) var connected = false
    private(set) var lastError: String?
    private(set) var notice: String?
    private(set) var queue: [QueueSong] = []
    private(set) var discovered: [DiscoveredPlayer] = []
    private(set) var discovering = false
    private(set) var manualPlayers: [KnownPlayer] = []
    private(set) var slaves: [GroupSlave] = []
    private(set) var playerName = ""
    private(set) var searchKey = ""
    private(set) var libraryNote: LibraryNote?
    private(set) var shares: [NetworkShare] = []
    private(set) var sharesLoaded = false
    private(set) var sharesBusy = false
    private(set) var shareError: String?
    private(set) var addShareForm = AddShareForm.fallback

    /// Rows with an add still in flight. A second click on the same row is ignored.
    private var pendingAdds: Set<String> = []
    /// Rows with a play still in flight.
    private var pendingPlays: Set<String> = []
    /// When the add checkmark turns back into a plus. One sweep serves every row.
    private var addedUntil: [String: Date] = [:]
    /// Amber play before `/Status` has moved on from the snapshot taken at success.
    private var playHold: PlayHold?

    var host: String
    var port: Int
    var menuBarExtra: Bool
    var sleepFadeEnabled: Bool
    var sleepFadeSeconds: Double
    var sleepEndStop: Bool

    @ObservationIgnored private var client: any BluOSClient
    /// Network failures clear on the next successful read. Other text stays.
    @ObservationIgnored private var lastErrorKind: ShownErrorKind = .other
    @ObservationIgnored private var recoveryTiming = NetworkRecoveryTiming()
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryGeneration = 0
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var reachabilityArmed = false
    @ObservationIgnored private var reachabilitySawPath = false
    @ObservationIgnored private var reachabilityUp = false
    @ObservationIgnored private var sleep: SleepFade
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var chain: Task<Void, Never>?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledWake: Date?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var loadedPID = ""
    /// True after a playlist fetch succeeds, including an empty queue. Stops a status loop from reloading it.
    @ObservationIgnored private var queueLoaded = false
    @ObservationIgnored private var lastQueueFetch = Date.distantPast
    /// Optimistic playhead. A stale `/Status` must not put the old second back.
    @ObservationIgnored private var seekLatch: SeekLatch?
    @ObservationIgnored private var seekGen = 0
    @ObservationIgnored private var volumeHoldUntil: Date?
    /// Set for the whole send, including the debounce, so a status poll cannot
    /// put the old level back before `/Volume` returns.
    @ObservationIgnored private var volumeInFlight = false
    /// Level before this gesture's first optimistic write. A failure reverts here.
    @ObservationIgnored private var volumeAnchor: Int?
    @ObservationIgnored private var volumeGen = 0
    @ObservationIgnored private var addNodes = 0
    @ObservationIgnored private var addSweep: Task<Void, Never>?
    @ObservationIgnored private var playSweep: Task<Void, Never>?
    @ObservationIgnored private var addSweepGen = 0
    @ObservationIgnored private var playSweepGen = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var playerEpoch = 0
    @ObservationIgnored private var sharePage: NetworkSharePage?
    @ObservationIgnored private var shareGeneration = 0
    @ObservationIgnored private var shareBusyCount = 0
    @ObservationIgnored private var commandsOpen = true
    @ObservationIgnored private var lastToggle = Date.distantPast

    static let shared = AppModel()
    static let libraryRoot = "LocalMusic:"
    static let playlistRoot = "BluOS:"

    var sleepCaption: String? { sleep.caption }

    var activePlayerTitle: String {
        if host.isEmpty { return "" }
        if let match = players.first(where: { isActive($0) }), !match.name.isEmpty {
            return match.name
        }
        return host
    }

    /// Window and menu-bar title. A host-only name is shown as `host:port`.
    var playerMenuTitle: String {
        if host.isEmpty { return "Choose a player" }
        let address = "\(host):\(port)"
        let title = activePlayerTitle
        if title.isEmpty || title == host || title == address { return address }
        return title
    }

    /// Discovered players, saved manual players, and the one we are controlling.
    var players: [KnownPlayer] {
        var map: [String: KnownPlayer] = [:]
        map.reserveCapacity(manualPlayers.count + discovered.count + 1)
        for manual in manualPlayers {
            map[manual.id] = manual
        }
        for found in discovered {
            let existing = map[found.id]
            let name = found.name.isEmpty ? (existing?.name ?? found.host) : found.name
            map[found.id] = KnownPlayer(
                name: name,
                host: found.host,
                port: found.port,
                manual: existing?.manual ?? false
            )
        }
        if !host.isEmpty {
            let activeID = "\(host):\(port)"
            if var active = map[activeID] {
                if active.name == active.host, !playerName.isEmpty {
                    active.name = playerName
                    map[activeID] = active
                }
            } else {
                map[activeID] = KnownPlayer(
                    name: playerName.isEmpty ? host : playerName,
                    host: host,
                    port: port,
                    manual: false
                )
            }
        }
        return map.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var groupCaption: String {
        var names: [String: String] = [:]
        names.reserveCapacity(players.count)
        for player in players where !player.name.isEmpty {
            names[player.id] = player.name
        }
        return GroupLabel.caption(slaves: slaves, names: names)
    }

    func isActive(_ player: KnownPlayer) -> Bool {
        player.host == host && player.port == port
    }

    func playerIsGrouped(_ player: KnownPlayer) -> Bool {
        slaves.contains { $0.host == player.host && $0.port == player.port }
    }

    init() {
        let defaults = UserDefaults.standard
        let storedHost = (defaults.string(forKey: "nightdeck.host") ?? NightdeckDefaults.host)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let storedPort = defaults.object(forKey: "nightdeck.port") as? Int ?? NightdeckDefaults.port
        let resolvedPort = (1...65535).contains(storedPort) ? storedPort : NightdeckDefaults.port
        let menu = defaults.object(forKey: "nightdeck.menuBar") as? Bool ?? true
        let fade = defaults.object(forKey: "nightdeck.sleepFade") as? Bool ?? true
        let secs = min(300, max(2, defaults.object(forKey: "nightdeck.sleepFadeSeconds") as? Double ?? 24))
        let endStop = defaults.bool(forKey: "nightdeck.sleepEndStop")
        host = storedHost
        port = resolvedPort
        menuBarExtra = menu
        sleepFadeEnabled = fade
        sleepFadeSeconds = secs
        sleepEndStop = endStop
        client = HTTPBluOSClient(host: storedHost, port: resolvedPort)
        sleep = SleepFade(config: SleepFadeConfig(enabled: fade, seconds: secs, endWithStop: endStop))
        manualPlayers = Self.loadManualPlayers()
    }

    func start() {
        guard !started else { return }
        started = true
        armReachability()
        if !host.isEmpty { restartPolling() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self.discover()
        }
    }

    func elapsed(at date: Date = Date()) -> Double {
        status.interpolatedSeconds(at: date)
    }

    func saveSettings() {
        sleepFadeSeconds = min(300, max(2, sleepFadeSeconds))
        sleep.updateConfig(SleepFadeConfig(
            enabled: sleepFadeEnabled,
            seconds: sleepFadeSeconds,
            endWithStop: sleepEndStop
        ))
        let defaults = UserDefaults.standard
        defaults.set(host, forKey: "nightdeck.host")
        defaults.set(port, forKey: "nightdeck.port")
        defaults.set(menuBarExtra, forKey: "nightdeck.menuBar")
        defaults.set(sleepFadeEnabled, forKey: "nightdeck.sleepFade")
        defaults.set(sleepFadeSeconds, forKey: "nightdeck.sleepFadeSeconds")
        defaults.set(sleepEndStop, forKey: "nightdeck.sleepEndStop")
        saveManualPlayers()
    }

    func setPlayer(host rawHost: String, port rawPort: Int) {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        var port = rawPort
        if host.hasPrefix("http://") { host.removeFirst(7) }
        if host.hasPrefix("https://") { host.removeFirst(8) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        if host.filter({ $0 == ":" }).count == 1, let colon = host.lastIndex(of: ":"),
           let parsed = Int(host[host.index(after: colon)...]) {
            host = String(host[..<colon])
            port = parsed
        }
        guard !host.isEmpty, !host.contains("@"), !host.contains(where: \.isWhitespace),
              (1...65535).contains(port) else {
            showError("Enter a host and port", kind: .other)
            return
        }
        playerEpoch += 1
        let epoch = playerEpoch
        let actions = sleep.abort(restoreVolume: true)
        sleep = SleepFade(config: SleepFadeConfig(
            enabled: sleepFadeEnabled,
            seconds: sleepFadeSeconds,
            endWithStop: sleepEndStop
        ))
        cancelWake()
        cancelRecovery()
        cancelVolumeSend()
        cancelSeek()
        pollTask?.cancel()
        chain?.cancel()
        commandsOpen = false
        self.host = host
        self.port = port
        saveSettings()
        status = PlayerStatus()
        queue = []
        loadedPID = ""
        queueLoaded = false
        searchKey = ""
        connected = false
        notice = nil
        clearLibraryFeedback()
        clearShares()
        slaves = []
        playerName = ""
        TransportUI.shared.resetTransient()
        // The old chain is cancelled, but cancellation is cooperative. Wait until it
        // actually returns before pointing the client at the new player. Epoch checks
        // stop any step that is still between requests.
        run {
            await self.performSleep(actions)
            guard !Task.isCancelled, epoch == self.playerEpoch else { return }
            self.retarget(host, port)
            self.commandsOpen = true
            self.restartPolling()
        }
    }

    func discover() async {
        if discovering { return }
        discovering = true
        defer { discovering = false }
        discovered = await PlayerDiscovery().browse(timeout: 2)
    }

    /// Opens the picker: Bonjour plus one `/SyncStatus` read. Does not group or switch.
    func refreshPicker() async {
        let epoch = playerEpoch
        await discover()
        guard epoch == playerEpoch else { return }
        await reloadGroup(epoch: epoch)
    }

    /// Click path. Does nothing when this player is already active.
    func selectPlayer(_ player: KnownPlayer) {
        guard !isActive(player) else { return }
        setPlayer(host: player.host, port: player.port)
    }

    /// Saves `host` or `host:port`. Does not connect or group.
    func addManualPlayer(_ text: String) {
        guard let parsed = PlayerAddress.parse(text) else {
            showError("Enter a host and port", kind: .other)
            return
        }
        if lastError == "Enter a host and port" { clearError() }
        let id = "\(parsed.host):\(parsed.port)"
        manualPlayers.removeAll { $0.id == id }
        manualPlayers.append(KnownPlayer(name: parsed.host, host: parsed.host, port: parsed.port, manual: true))
        saveManualPlayers()
    }

    func removeManualPlayer(id: String) {
        manualPlayers.removeAll { $0.id == id }
        saveManualPlayers()
    }

    /// Click path only. The active player is the master. Re-reads `/SyncStatus` after the command.
    func toggleGroup(_ player: KnownPlayer) {
        guard commandsOpen, connected, !isActive(player) else { return }
        let epoch = playerEpoch
        let slaveHost = player.host
        let slavePort = player.port
        attempt {
            guard epoch == self.playerEpoch, self.commandsOpen else { return }
            let adding = !self.slaves.contains { $0.host == slaveHost && $0.port == slavePort }
            do {
                if adding {
                    try await self.client.addSlave(host: slaveHost, port: slavePort)
                } else {
                    try await self.client.removeSlave(host: slaveHost, port: slavePort)
                }
            } catch is CancellationError {
                return
            } catch {
                guard epoch == self.playerEpoch else { return }
                self.showError("Group failed: \(self.message(error))", kind: .other)
                await self.reloadGroup(epoch: epoch)
                return
            }
            guard epoch == self.playerEpoch else { return }
            await self.reloadGroup(epoch: epoch)
        }
    }

    func togglePlayPause() {
        guard connected, commandsOpen, takeToggle() else { return }
        abortSleep(restore: true)
        let playing = status.state.isPlaying
        status.state = playing ? .pause : .play
        status.receivedAt = Date()
        attempt {
            if playing { try await self.client.pause(toggle: true) }
            else { try await self.client.play(id: nil) }
        }
    }

    func next() {
        guard connected, commandsOpen else { return }
        attempt { try await self.client.skip() }
    }

    func previous() {
        guard connected, commandsOpen else { return }
        attempt { try await self.client.back() }
    }

    /// Same chain as pause: connected, commands open, sleep aborted, one `/Stop`.
    func stopPlayback() {
        guard connected, commandsOpen, status.state != .stop else { return }
        abortSleep(restore: true)
        status.state = .stop
        status.seconds = 0
        status.receivedAt = Date()
        attempt { try await self.client.stop() }
    }

    /// Polls a loopback player. Does not write the saved host.
    func attachPreview(host: String, port: Int) {
        playerEpoch += 1
        pollTask?.cancel()
        chain?.cancel()
        cancelVolumeSend()
        cancelSeek()
        cancelWake()
        cancelRecovery()
        commandsOpen = false
        self.host = host
        self.port = port
        slaves = []
        playerName = ""
        searchKey = ""
        queue = []
        loadedPID = ""
        queueLoaded = false
        status = PlayerStatus()
        clearError()
        clearLibraryFeedback()
        clearShares()
        TransportUI.shared.resetTransient()
        retarget(host, port)
        commandsOpen = true
        armReachability()
        restartPolling()
    }

    /// Test hook. Polls `client` instead of the saved player. Does not write settings.
    func attachClient(_ client: any BluOSClient, host: String, port: Int) {
        self.client = client
        attachPreview(host: host, port: port)
    }

    /// Shortens the post-wake pause so tests can watch a refresh without the real delay.
    func setRecoveryTiming(settle: TimeInterval, pauses: [TimeInterval]) {
        recoveryTiming = NetworkRecoveryTiming(settle: settle, pauses: pauses)
    }

    func endPreview() {
        playerEpoch += 1
        commandsOpen = false
        cancelRecovery()
        disarmReachability()
        pollTask?.cancel()
        chain?.cancel()
        cancelVolumeSend()
        cancelSeek()
        cancelWake()
        clearLibraryFeedback()
        clearShares()
        pollTask = nil
        chain = nil
    }

    /// Loads the player's network shares. Does nothing until a player is connected.
    func reloadShares() async {
        shareGeneration += 1
        let generation = shareGeneration
        let epoch = playerEpoch
        guard connected, commandsOpen, !host.isEmpty else {
            if generation == shareGeneration {
                shares = []
                sharePage = nil
                sharesLoaded = false
                shareError = nil
            }
            return
        }
        beginShareWork()
        defer { endShareWork() }
        retarget(host, port)
        do {
            let page = try await client.networkShares()
            guard generation == shareGeneration, epoch == playerEpoch else { return }
            applyShares(page)
            shareError = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == shareGeneration, epoch == playerEpoch else { return }
            shareError = message(error)
        }
    }

    func loadAddShareForm() async {
        guard connected, commandsOpen, !host.isEmpty else { return }
        let epoch = playerEpoch
        retarget(host, port)
        do {
            let form = try await client.addShareForm()
            guard epoch == playerEpoch else { return }
            addShareForm = form
        } catch is CancellationError {
            return
        } catch {
            guard epoch == playerEpoch else { return }
            addShareForm = .fallback
        }
    }

    /// Sends the share. The password is not stored. Throws the player's error text.
    func addShare(name: String, username: String, password: String) async throws {
        guard connected, commandsOpen, !host.isEmpty else {
            throw BluOSError.unreachable(host.isEmpty ? "Player not reachable" : "Player not reachable at \(host)")
        }
        shareGeneration += 1
        let generation = shareGeneration
        let epoch = playerEpoch
        let endpointHost = host
        let endpointPort = port
        beginShareWork()
        defer { endShareWork() }
        retarget(endpointHost, endpointPort)
        let form = try await client.addShareForm()
        guard epoch == playerEpoch, host == endpointHost, port == endpointPort else { return }
        addShareForm = form
        let page = try await client.addShare(name: name, username: username, password: password, form: form)
        guard generation == shareGeneration, epoch == playerEpoch else { return }
        applyShares(page)
        shareError = nil
    }

    func removeShares(_ paths: [String]) async {
        guard connected, commandsOpen, !paths.isEmpty, let page = sharePage else { return }
        shareGeneration += 1
        let generation = shareGeneration
        let epoch = playerEpoch
        beginShareWork()
        defer { endShareWork() }
        retarget(host, port)
        do {
            let updated = try await client.removeShares(paths, from: page)
            guard generation == shareGeneration, epoch == playerEpoch else { return }
            applyShares(updated)
            shareError = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == shareGeneration, epoch == playerEpoch else { return }
            shareError = message(error)
        }
    }

    func reindexLibrary() async {
        guard connected, commandsOpen, !host.isEmpty else { return }
        let epoch = playerEpoch
        beginShareWork()
        defer { endShareWork() }
        retarget(host, port)
        do {
            try await client.reindex()
            guard epoch == playerEpoch else { return }
            if status.indexing < 1 { status.indexing = 1 }
            shareError = nil
        } catch is CancellationError {
            return
        } catch {
            guard epoch == playerEpoch else { return }
            shareError = message(error)
        }
    }

    func seek(to seconds: Double) {
        guard connected, commandsOpen else {
            notice = "Seek was not sent"
            return
        }
        guard status.seekable else { return }
        let upper = Double(max(status.total, 0))
        let target = Int(max(0, min(seconds, upper)).rounded())
        let anchor = status.seconds
        let anchorAt = status.receivedAt
        let askedAt = Date()
        status.seconds = target
        status.receivedAt = askedAt
        seekLatch = SeekLatch(target: target, anchor: anchor, askedAt: askedAt, until: askedAt.addingTimeInterval(8))
        seekGen += 1
        let generation = seekGen
        let epoch = playerEpoch
        let endpointHost = host
        let endpointPort = port
        attempt {
            guard generation == self.seekGen, epoch == self.playerEpoch else { return }
            guard self.host == endpointHost, self.port == endpointPort, self.commandsOpen else {
                self.notice = "Seek was not sent"
                return
            }
            self.retarget(endpointHost, endpointPort)
            do {
                try await self.client.seek(target)
                guard generation == self.seekGen, epoch == self.playerEpoch else { return }
                self.clearSeekNotice()
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.seekGen, epoch == self.playerEpoch else { return }
                self.seekLatch = nil
                self.status.seconds = anchor
                self.status.receivedAt = anchorAt
                self.notice = "Seek failed: \(self.message(error))"
                throw error
            }
        }
    }

    func setVolume(_ level: Int) {
        guard connected, commandsOpen else {
            notice = "Volume was not sent"
            return
        }
        let clamped = min(100, max(0, level))
        abortSleep(restore: false)
        let endpointHost = host
        let endpointPort = port
        if !volumeInFlight {
            volumeAnchor = status.volume
        }
        volumeInFlight = true
        status.volume = clamped
        volumeHoldUntil = Date().addingTimeInterval(1.2)
        volumeGen += 1
        let generation = volumeGen
        let epoch = playerEpoch
        volumeTask?.cancel()
        volumeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            // A newer drag owns the flag. Do not revert its level or clear it.
            guard !Task.isCancelled, generation == self.volumeGen, epoch == self.playerEpoch else { return }
            guard self.host == endpointHost, self.port == endpointPort, self.commandsOpen else {
                self.volumeInFlight = false
                self.notice = "Volume was not sent"
                return
            }
            self.attempt {
                guard generation == self.volumeGen, epoch == self.playerEpoch else { return }
                guard self.host == endpointHost, self.port == endpointPort else { return }
                self.retarget(endpointHost, endpointPort)
                do {
                    let state = try await self.client.setVolume(level: clamped)
                    guard generation == self.volumeGen, epoch == self.playerEpoch else { return }
                    if state.level >= 0 { self.status.volume = state.level }
                    if !state.db.isEmpty { self.status.db = state.db }
                    self.volumeAnchor = self.status.volume
                    self.volumeInFlight = false
                    self.volumeHoldUntil = Date().addingTimeInterval(1.2)
                    self.clearVolumeNotice()
                } catch is CancellationError {
                    if generation == self.volumeGen, epoch == self.playerEpoch {
                        self.volumeInFlight = false
                    }
                } catch {
                    guard generation == self.volumeGen, epoch == self.playerEpoch else { return }
                    self.volumeInFlight = false
                    self.volumeHoldUntil = nil
                    if let anchor = self.volumeAnchor {
                        self.status.volume = anchor
                    }
                    self.notice = "Volume failed: \(self.message(error))"
                    throw error
                }
            }
        }
    }

    func toggleMute() {
        guard connected, commandsOpen else { return }
        abortSleep(restore: true)
        let on = !status.mute
        status.mute = on
        volumeHoldUntil = Date().addingTimeInterval(1.5)
        attempt {
            do {
                let state = try await self.client.setMute(on)
                self.status.mute = state.mute
                if state.level >= 0 { self.status.volume = state.level }
                if !state.db.isEmpty { self.status.db = state.db }
                if !state.muteDB.isEmpty { self.status.muteDB = state.muteDB }
            } catch {
                self.status.mute = !on
                throw error
            }
        }
    }

    func toggleShuffle() {
        guard connected, commandsOpen else { return }
        let previous = status.shuffle
        let on = !previous
        status.shuffle = on
        attempt {
            do { try await self.client.setShuffle(on) }
            catch {
                self.status.shuffle = previous
                throw error
            }
        }
    }

    func cycleRepeat() {
        guard connected, commandsOpen else { return }
        let previous = status.repeatMode
        let next = previous.next
        status.repeatMode = next
        attempt {
            do { try await self.client.setRepeat(next) }
            catch {
                self.status.repeatMode = previous
                throw error
            }
        }
    }

    func cycleSleep() {
        guard connected, commandsOpen else { return }
        let epoch = playerEpoch
        let actions = sleep.abort(restoreVolume: true)
        run {
            await self.performSleep(actions)
            guard self.still(epoch), self.connected, self.commandsOpen else { return }
            self.sleep.beginCommand()
            do {
                let minutes = try await self.client.sleep()
                guard self.still(epoch) else {
                    self.sleep.endCommand()
                    return
                }
                self.sleep.noteCommanded(minutes: minutes)
                self.status.sleepMinutes = minutes
                self.notice = minutes > 0 ? "Sleep timer: \(minutes) min" : "Sleep timer: off"
            } catch is CancellationError {
                self.sleep.endCommand()
            } catch {
                guard self.still(epoch) else {
                    self.sleep.endCommand()
                    return
                }
                self.sleep.endCommand()
                self.show(error)
            }
        }
    }

    func refreshQueue() { run { await self.reloadQueue() } }

    func playQueueSong(_ song: QueueSong) {
        guard connected, commandsOpen else { return }
        let epoch = playerEpoch
        attempt {
            guard self.still(epoch) else { return }
            let id = self.queue.first { $0.file == song.file && !$0.file.isEmpty && $0.title == song.title }?.id ?? song.id
            try await self.client.play(id: id)
        }
    }

    func removeQueueSong(_ id: Int) {
        guard connected, commandsOpen, let song = queue.first(where: { $0.id == id }) else { return }
        let epoch = playerEpoch
        attempt {
            guard self.still(epoch), let live = self.queue.first(where: { Self.sameTrack($0, song) }) else { return }
            try await self.client.deleteSong(id: live.id)
            guard self.still(epoch) else { return }
            await self.reloadQueue(epoch: epoch)
        }
    }

    func moveQueueSong(from: Int, toOffset: Int) {
        guard connected, commandsOpen, queue.indices.contains(from) else { return }
        let song = queue[from]
        let epoch = playerEpoch
        attempt {
            guard self.still(epoch), let live = self.queue.firstIndex(where: { Self.sameTrack($0, song) }) else { return }
            let shift = live - from
            let dest = queueMoveDestination(from: live, toOffset: toOffset + shift)
            guard self.queue.indices.contains(dest), dest != live else { return }
            let current = self.queue.remove(at: live)
            self.queue.insert(current, at: dest)
            do { try await self.client.moveSong(from: current.id, to: dest) }
            catch {
                guard self.still(epoch) else { return }
                self.show(error)
            }
            guard self.still(epoch) else { return }
            await self.reloadQueue(epoch: epoch)
        }
    }

    func clearQueue() {
        guard connected, commandsOpen else { return }
        let epoch = playerEpoch
        attempt {
            guard self.still(epoch) else { return }
            try await self.client.clearQueue()
            guard self.still(epoch) else { return }
            await self.reloadQueue(epoch: epoch)
        }
    }

    func browse(key: String) async -> BrowsePage? {
        await fetchBrowse(key: key, query: nil)
    }

    func search(query: String) async -> BrowsePage? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let key = searchKey.isEmpty ? "LocalMusic:Search" : searchKey
        return await fetchBrowse(key: key, query: text)
    }

    func addToQueue(_ item: BrowseItem, now: Bool) {
        guard connected, commandsOpen else { return }
        let id = item.id
        if now {
            guard pendingPlays.insert(id).inserted else { return }
        } else {
            guard pendingAdds.insert(id).inserted else { return }
        }
        let epoch = playerEpoch
        run {
            defer {
                if epoch == self.playerEpoch {
                    if now { self.pendingPlays.remove(id) }
                    else { self.pendingAdds.remove(id) }
                }
            }
            guard self.still(epoch) else { return }
            self.addNodes = 0
            do {
                let queued = try await self.enqueue(item, now: now, depth: 0, epoch: epoch)
                guard self.still(epoch) else { return }
                if !queued {
                    self.failLibrary(id: id, play: now, message: "Nothing was added", epoch: epoch)
                }
                guard self.still(epoch) else { return }
                await self.reloadQueue(epoch: epoch)
                guard self.still(epoch), queued else { return }
                self.clearNetworkError()
                if now { self.notePlay(item, epoch: epoch) }
                else { self.noteAdd(item, epoch: epoch) }
            } catch is CancellationError {
                return
            } catch {
                guard self.still(epoch) else { return }
                let message = self.message(error)
                self.show(error)
                self.failLibrary(id: id, play: now, message: message, epoch: epoch)
                await self.reloadQueue(epoch: epoch)
            }
        }
    }

    func libraryAddCue(for item: BrowseItem) -> LibraryCue {
        if pendingAdds.contains(item.id) { return .pending }
        if let until = addedUntil[item.id], until > Date() { return .added }
        return .idle
    }

    func libraryPlayCue(for item: BrowseItem) -> LibraryCue {
        if pendingPlays.contains(item.id) { return .pending }
        if playAccent(item) { return .playing }
        return .idle
    }

    func savedPlaylists() async -> [BrowseItem] {
        var key = Self.playlistRoot
        var items: [BrowseItem] = []
        var seen = Set<String>()
        var pages = 0
        while !key.isEmpty, pages < 20, seen.insert(key).inserted {
            guard let page = await fetchBrowse(key: key, query: nil) else { break }
            items.append(contentsOf: page.items.filter { !$0.text.isEmpty && !$0.playURL.isEmpty })
            key = page.nextKey
            pages += 1
        }
        return items
    }

    func saveQueue(named name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, commandsOpen, !host.isEmpty, !trimmed.isEmpty else { return false }
        if queue.isEmpty {
            showError("The queue is empty", kind: .other)
            return false
        }
        let epoch = playerEpoch
        do {
            _ = try await client.savePlaylist(name: trimmed)
            guard still(epoch) else { return false }
            notice = "Saved playlist “\(trimmed)”"
            clearNetworkError()
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard still(epoch) else { return false }
            show(error)
            return false
        }
    }

    func loadPlaylist(_ item: BrowseItem) async {
        guard connected, commandsOpen, !item.playURL.isEmpty else { return }
        let epoch = playerEpoch
        do {
            try await client.perform(item.playURL)
            guard still(epoch) else { return }
            await reloadQueue()
            guard still(epoch) else { return }
            notice = "Loaded \(item.text)"
        } catch is CancellationError {
            return
        } catch {
            guard still(epoch) else { return }
            show(error)
        }
    }

    func deletePlaylist(_ item: BrowseItem) async {
        guard connected, commandsOpen else { return }
        let epoch = playerEpoch
        do {
            if !item.contextMenuKey.isEmpty {
                let menu = try await client.browse(key: item.contextMenuKey, query: nil)
                guard still(epoch) else { return }
                if let hit = menu.items.first(where: { $0.type == "delete" && !$0.actionURL.isEmpty }) {
                    try await client.perform(hit.actionURL)
                    guard still(epoch) else { return }
                    notice = "Deleted \(item.text)"
                    clearNetworkError()
                    return
                }
            }
            guard still(epoch) else { return }
            try await client.deletePlaylist(name: item.text)
            guard still(epoch) else { return }
            notice = "Deleted \(item.text)"
            clearNetworkError()
        } catch is CancellationError {
            return
        } catch {
            guard still(epoch) else { return }
            show(error)
        }
    }

    func loadPresets() async -> [Preset] {
        guard !host.isEmpty, commandsOpen else { return [] }
        let epoch = playerEpoch
        do {
            let presets = try await client.presets()
            guard still(epoch) else { return [] }
            clearNetworkError()
            return presets
        } catch is CancellationError {
            return []
        } catch {
            guard still(epoch) else { return [] }
            show(error)
            return []
        }
    }

    func playPreset(_ preset: Preset) {
        guard connected, commandsOpen else { return }
        let epoch = playerEpoch
        attempt {
            guard self.still(epoch) else { return }
            try await self.client.playPreset(id: preset.id)
            guard self.still(epoch) else { return }
            await self.reloadQueue(epoch: epoch)
            guard self.still(epoch) else { return }
            self.notice = "Preset \(preset.name)"
        }
    }

    func artwork(path: String) async -> Data? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        do {
            let data = try await client.fetchData(trimmed)
            clearNetworkError()
            return data
        } catch {
            return nil
        }
    }

    private func fetchBrowse(key: String, query: String?) async -> BrowsePage? {
        // Closed while a switch is still pointing the client at the previous player.
        guard !host.isEmpty, commandsOpen else { return nil }
        let epoch = playerEpoch
        do {
            let page = try await client.browse(key: key, query: query)
            guard still(epoch) else { return nil }
            if !page.searchKey.isEmpty { searchKey = page.searchKey }
            clearNetworkError()
            return page
        } catch is CancellationError {
            return nil
        } catch {
            guard still(epoch) else { return nil }
            show(error)
            return nil
        }
    }

    /// True when a song was actually queued. Skipped rows do not consume play-now.
    private func enqueue(_ item: BrowseItem, now: Bool, depth: Int, epoch: Int) async throws -> Bool {
        guard still(epoch) else { throw CancellationError() }
        addNodes += 1
        if addNodes > 1500 { throw BluOSError.player("Too many items to add") }
        if !item.contextMenuKey.isEmpty {
            let menu = try await client.browse(key: item.contextMenuKey, query: nil)
            guard still(epoch) else { throw CancellationError() }
            let want: Set<String> = now ? ["add-now", "addAll-now"] : ["add-last", "addAll-last"]
            if let hit = menu.items.first(where: { want.contains($0.type) && !$0.actionURL.isEmpty }) {
                try await client.perform(hit.actionURL)
                return true
            }
        }
        let skip: Set<String> = ["section", "link", "genre"]
        if item.isContainer, depth < 3, !skip.contains(item.type) {
            var key = item.browseKey
            var playFirst = now
            var queued = false
            var seen = Set<String>()
            var pages = 0
            while !key.isEmpty, pages < 40, seen.insert(key).inserted {
                guard still(epoch) else { throw CancellationError() }
                let page = try await client.browse(key: key, query: nil)
                guard still(epoch) else { throw CancellationError() }
                if !page.searchKey.isEmpty { searchKey = page.searchKey }
                for sub in page.items {
                    if try await enqueue(sub, now: playFirst, depth: depth + 1, epoch: epoch) {
                        queued = true
                        playFirst = false
                    }
                }
                key = page.nextKey
                pages += 1
            }
            return queued
        }
        guard !item.playURL.isEmpty else { return false }
        guard still(epoch) else { throw CancellationError() }
        let url = now ? QueueActions.playNowURL(item.playURL) : QueueActions.addLastURL(item.playURL)
        try await client.perform(url)
        return true
    }

    private static func loadManualPlayers() -> [KnownPlayer] {
        let lines = UserDefaults.standard.stringArray(forKey: "nightdeck.manualPlayers") ?? []
        var seen = Set<String>()
        var players: [KnownPlayer] = []
        for line in lines {
            guard let parsed = PlayerAddress.parse(line) else { continue }
            let id = "\(parsed.host):\(parsed.port)"
            guard seen.insert(id).inserted else { continue }
            players.append(KnownPlayer(name: parsed.host, host: parsed.host, port: parsed.port, manual: true))
        }
        return players
    }

    private func saveManualPlayers() {
        UserDefaults.standard.set(
            manualPlayers.map { "\($0.host):\($0.port)" },
            forKey: "nightdeck.manualPlayers"
        )
    }

    private func applySync(_ sync: SyncStatus) {
        if !sync.name.isEmpty { playerName = sync.name }
        slaves = sync.slaves.filter { slave in
            !slave.host.isEmpty && !(slave.host == host && slave.port == port)
        }
    }

    private func reloadGroup(epoch: Int) async {
        guard epoch == playerEpoch, commandsOpen, !host.isEmpty else { return }
        do {
            let sync = try await client.syncStatus()
            guard epoch == playerEpoch else { return }
            applySync(sync)
            clearNetworkError()
        } catch is CancellationError {
            return
        } catch {
            guard epoch == playerEpoch else { return }
            if lastError == nil { show(error) }
        }
    }

    private func restartPolling() {
        beginPolling(resetState: true)
    }

    /// `resetState` is false after wake: keep the queue and the connected flag, then long-poll again.
    private func beginPolling(resetState: Bool) {
        pollTask?.cancel()
        if resetState { cancelWake() }
        guard !host.isEmpty else {
            connected = false
            return
        }
        retarget(host, port)
        if resetState {
            connected = false
            loadedPID = ""
            queueLoaded = false
        }
        let epoch = playerEpoch
        let poller = StatusPoller(client: client)
        pollTask = Task { @MainActor in
            let stream = poller.events()
            for await event in stream {
                if Task.isCancelled || epoch != self.playerEpoch { break }
                switch event {
                case .status(let status): self.apply(status)
                case .failure(let failure): self.fail(failure)
                }
            }
        }
    }

    private func apply(_ incoming: PlayerStatus) {
        let next = merge(incoming)
        let now = Date()
        let reconnected = !connected
        status = next
        connected = true
        if reconnected {
            clearError()
            let epoch = playerEpoch
            run {
                guard epoch == self.playerEpoch else { return }
                await self.reloadGroup(epoch: epoch)
            }
        } else {
            clearNetworkError()
        }
        sleep.updateConfig(SleepFadeConfig(
            enabled: sleepFadeEnabled,
            seconds: sleepFadeSeconds,
            endWithStop: sleepEndStop
        ))
        let (actions, wake) = sleep.tick(status: status, now: now, confirmed: false)
        scheduleWake(wake)
        if !actions.isEmpty { run { await self.performSleep(actions) } }
        let pidChanged = next.playlistID != loadedPID
        let needSongs = !queueLoaded && queue.isEmpty && next.song >= 0
        // A new playlist id is a real change and is not throttled. The empty-queue
        // retry is, so a failed first fetch cannot follow every status poll.
        let retry = needSongs && now.timeIntervalSince(lastQueueFetch) > 2
        if pidChanged || retry {
            lastQueueFetch = now
            let epoch = playerEpoch
            run { await self.reloadQueue(epoch: epoch) }
        }
        reconcilePlayHold()
    }

    private func merge(_ incoming: PlayerStatus) -> PlayerStatus {
        var next = incoming
        let now = Date()
        if incoming.song != status.song || incoming.playlistID != status.playlistID {
            seekLatch = nil
        } else if let latch = seekLatch {
            // Keep the drop point until a report is actually there. A poll that left
            // before the seek still carries the old second.
            if latch.confirms(incoming.seconds, now: now) || now >= latch.until {
                seekLatch = nil
            } else {
                next.seconds = status.seconds
                next.receivedAt = status.receivedAt
            }
        }
        let holdingVolume = volumeInFlight || (volumeHoldUntil.map { now < $0 } ?? false)
        if holdingVolume {
            next.volume = status.volume
            next.db = status.db
            next.mute = status.mute
        } else {
            volumeHoldUntil = nil
        }
        return next
    }

    /// Drops a volume send that has not finished. Does not talk to the player.
    private func cancelVolumeSend() {
        volumeGen += 1
        volumeTask?.cancel()
        volumeTask = nil
        volumeInFlight = false
        volumeAnchor = nil
        volumeHoldUntil = nil
    }

    /// Drops a seek whose result must not land on a player we have since left.
    private func cancelSeek() {
        seekGen += 1
        seekLatch = nil
    }

    private func clearSeekNotice() {
        if notice == "Seek was not sent" || notice?.hasPrefix("Seek failed:") == true {
            notice = nil
        }
    }

    private func clearVolumeNotice() {
        if notice == "Volume was not sent" || notice?.hasPrefix("Volume failed:") == true {
            notice = nil
        }
    }

    private func fail(_ failure: PollFailure) {
        connected = false
        showError(failure.message, kind: failure.network ? .network : .other)
        abortSleep(restore: true)
    }

    private func tickSleep() {
        let epoch = playerEpoch
        run {
            guard epoch == self.playerEpoch else { return }
            await self.finishSleepWake(epoch: epoch)
        }
    }

    private func finishSleepWake(epoch: Int) async {
        guard still(epoch) else { return }
        if self.sleep.needsConfirm(status: self.status, now: Date()) {
            do {
                let fresh = try await self.client.status(timeout: nil, etag: nil)
                guard still(epoch) else { return }
                self.status = self.merge(fresh)
                self.connected = true
            } catch is CancellationError {
                return
            } catch {
                guard still(epoch) else { return }
                _ = self.sleep.abort(restoreVolume: false)
                return
            }
        }
        guard still(epoch) else { return }
        let (actions, wake) = self.sleep.tick(status: self.status, now: Date())
        guard still(epoch) else { return }
        self.scheduleWake(wake)
        if !actions.isEmpty { await self.performSleep(actions) }
    }

    private func scheduleWake(_ date: Date?) {
        guard let date else {
            cancelWake()
            return
        }
        if let scheduledWake, let wakeTask, !wakeTask.isCancelled,
           scheduledWake.timeIntervalSince(date) <= 0.05 {
            return
        }
        scheduledWake = date
        wakeTask?.cancel()
        wakeTask = Task { @MainActor in
            let delay = date.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(delay, 3600) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            if self.scheduledWake == date { self.scheduledWake = nil }
            self.tickSleep()
        }
    }

    private func abortSleep(restore: Bool) {
        let actions = sleep.abort(restoreVolume: restore)
        guard !actions.isEmpty else { return }
        cancelWake()
        run { await self.performSleep(actions) }
    }

    private func cancelWake() {
        wakeTask?.cancel()
        wakeTask = nil
        scheduledWake = nil
    }

    private func performSleep(_ actions: [SleepFadeAction]) async {
        let epoch = playerEpoch
        for action in actions {
            if Task.isCancelled || epoch != playerEpoch { return }
            do {
                switch action {
                case .setVolume(let level):
                    let state = try await client.setVolume(level: level)
                    guard still(epoch) else { return }
                    status.volume = level
                    if state.level >= 0 { status.volume = state.level }
                    if !state.db.isEmpty { status.db = state.db }
                    volumeHoldUntil = Date().addingTimeInterval(1.2)
                case .pause:
                    try await client.pause(toggle: false)
                case .stop:
                    try await client.stop()
                case .notify(let event):
                    guard still(epoch) else { return }
                    notice = Self.noticeText(event)
                }
            } catch is CancellationError {
                return
            } catch {
                guard still(epoch) else { return }
                show(error)
                return
            }
        }
    }

    private func reloadQueue(epoch: Int? = nil) async {
        let epoch = epoch ?? playerEpoch
        guard still(epoch), !host.isEmpty else { return }
        do {
            let playlist = try await client.playlist()
            guard still(epoch) else { return }
            queue = playlist.songs
            loadedPID = playlist.id
            queueLoaded = true
            lastQueueFetch = Date()
            clearNetworkError()
        } catch is CancellationError {
            return
        } catch {
            guard still(epoch) else { return }
            show(error)
        }
    }

    private struct PlaybackStamp: Equatable {
        var playlistID: String
        var title: String
        var album: String
        var song: Int
        var file: String

        init(_ status: PlayerStatus) {
            playlistID = status.playlistID
            title = status.title
            album = status.album
            song = status.song
            file = status.file
        }
    }

    private struct PlayHold: Equatable {
        var item: BrowseItem
        var stamp: PlaybackStamp
        var until: Date
    }

    private func noteAdd(_ item: BrowseItem, epoch: Int) {
        guard still(epoch) else { return }
        addedUntil[item.id] = Date().addingTimeInterval(LibraryFeedbackTiming.addConfirmSeconds)
        libraryNote = .confirmation("Added to queue: \(Self.libraryTitle(item))")
        scheduleAddSweep()
    }

    private func notePlay(_ item: BrowseItem, epoch: Int) {
        guard still(epoch) else { return }
        playHold = PlayHold(
            item: item,
            stamp: PlaybackStamp(status),
            until: Date().addingTimeInterval(LibraryFeedbackTiming.playHoldSeconds)
        )
        if libraryNote?.isFailure == true { libraryNote = nil }
        schedulePlaySweep()
    }

    private func failLibrary(id: String, play: Bool, message: String, epoch: Int) {
        guard still(epoch) else { return }
        if play {
            if playHold?.item.id == id { playHold = nil }
        } else {
            addedUntil.removeValue(forKey: id)
        }
        libraryNote = .failure(message)
    }

    private func playAccent(_ item: BrowseItem) -> Bool {
        if NowPlayingMatch.matches(item, status: status) { return true }
        guard let playHold, playHold.item.id == item.id else { return false }
        guard PlaybackStamp(status) == playHold.stamp, Date() < playHold.until else { return false }
        return true
    }

    /// Drops the optimistic play mark once `/Status` is a different snapshot.
    private func reconcilePlayHold() {
        guard let playHold else { return }
        guard PlaybackStamp(status) != playHold.stamp else { return }
        self.playHold = nil
    }

    private func applyShares(_ page: NetworkSharePage) {
        sharePage = page
        shares = page.shares
        sharesLoaded = true
    }

    private func clearShares() {
        shareGeneration += 1
        shareBusyCount = 0
        sharesBusy = false
        shares = []
        sharePage = nil
        sharesLoaded = false
        shareError = nil
        addShareForm = .fallback
    }

    private func beginShareWork() {
        shareBusyCount += 1
        sharesBusy = true
    }

    private func endShareWork() {
        shareBusyCount = max(0, shareBusyCount - 1)
        sharesBusy = shareBusyCount > 0
    }

    private func clearLibraryFeedback() {
        pendingAdds = []
        pendingPlays = []
        addedUntil = [:]
        playHold = nil
        libraryNote = nil
        addSweep?.cancel()
        addSweep = nil
        addSweepGen += 1
        playSweep?.cancel()
        playSweep = nil
        playSweepGen += 1
    }

    private func scheduleAddSweep() {
        addSweep?.cancel()
        addSweepGen += 1
        let generation = addSweepGen
        let now = Date()
        addedUntil = addedUntil.filter { $0.value > now }
        guard let next = addedUntil.values.min() else { return }
        let delay = max(0, next.timeIntervalSinceNow)
        addSweep = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((delay + 0.05) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.addSweepGen == generation else { return }
            self.scheduleAddSweep()
        }
    }

    private func schedulePlaySweep() {
        playSweep?.cancel()
        playSweepGen += 1
        let generation = playSweepGen
        guard let until = playHold?.until else { return }
        let delay = max(0, until.timeIntervalSinceNow)
        playSweep = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((delay + 0.05) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.playSweepGen == generation else { return }
            guard let hold = self.playHold, Date() >= hold.until else { return }
            if PlaybackStamp(self.status) == hold.stamp { self.playHold = nil }
        }
    }

    private static func libraryTitle(_ item: BrowseItem) -> String {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        let text2 = item.text2.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text2.isEmpty { return text2 }
        return "item"
    }

    private func still(_ epoch: Int) -> Bool {
        epoch == playerEpoch && !Task.isCancelled
    }

    private func attempt(_ body: @escaping @MainActor () async throws -> Void) {
        guard commandsOpen else { return }
        run {
            guard self.commandsOpen else { return }
            do {
                let before = self.lastError
                try await body()
                if self.lastError == before { self.clearError() }
            } catch is CancellationError {
                return
            } catch {
                self.show(error)
            }
        }
    }

    private static func sameTrack(_ a: QueueSong, _ b: QueueSong) -> Bool {
        if !a.file.isEmpty || !b.file.isEmpty { return a.file == b.file && a.title == b.title }
        return a.id == b.id && a.title == b.title
    }

    private func takeToggle() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastToggle) > 0.3 else { return false }
        lastToggle = now
        return true
    }

    private func run(_ body: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await body()
        }
    }

    private func message(_ error: Error) -> String {
        PlayerMessages.describe(error, host: host)
    }

    private func showError(_ text: String, kind: ShownErrorKind) {
        lastError = text
        lastErrorKind = kind
    }

    private func show(_ error: Error) {
        let kind: ShownErrorKind = PlayerMessages.isNetwork(error) ? .network : .other
        showError(message(error), kind: kind)
    }

    private func clearError() {
        lastError = nil
        lastErrorKind = .other
    }

    /// A later successful read drops a stale "player not reachable" line.
    /// "Group failed" and "The queue is empty" stay until a command clears them.
    private func clearNetworkError() {
        guard lastErrorKind == .network else { return }
        clearError()
    }

    private func retarget(_ host: String, _ port: Int) {
        (client as? HTTPBluOSClient)?.setEndpoint(host: host, port: port)
    }

    private func armReachability() {
        guard !reachabilityArmed else { return }
        reachabilityArmed = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteSystemWake()
            }
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                self?.noteNetworkPath(satisfied: satisfied)
            }
        }
        pathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "nightdeck.path"))
    }

    private func disarmReachability() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        pathMonitor?.cancel()
        pathMonitor = nil
        reachabilityArmed = false
        reachabilitySawPath = false
        reachabilityUp = false
    }

    /// Same entry `NSWorkspace.didWakeNotification` uses. Read-only refresh, no transport.
    func noteSystemWake() {
        scheduleRecovery()
    }

    /// Same entry the path monitor uses. The first sample only records the current path.
    func noteNetworkPath(satisfied: Bool) {
        let becameSatisfied = reachabilitySawPath && satisfied && !reachabilityUp
        reachabilitySawPath = true
        reachabilityUp = satisfied
        if becameSatisfied { scheduleRecovery() }
    }

    private func scheduleRecovery() {
        guard !host.isEmpty, commandsOpen else { return }
        recoveryGeneration += 1
        let generation = recoveryGeneration
        let epoch = playerEpoch
        recoveryTask?.cancel()
        let settle = recoveryTiming.settle
        let pauses = recoveryTiming.pauses
        recoveryTask = Task { @MainActor in
            if settle > 0 {
                try? await Task.sleep(nanoseconds: Self.nanos(settle))
            }
            guard !Task.isCancelled, generation == self.recoveryGeneration, epoch == self.playerEpoch else { return }
            await self.recover(generation: generation, epoch: epoch, pauses: pauses)
        }
    }

    private func cancelRecovery() {
        recoveryGeneration += 1
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    /// After the link returns: one immediate `/Status`, then the visible queue or library, a few times.
    private func recover(generation: Int, epoch: Int, pauses: [TimeInterval]) async {
        pollTask?.cancel()
        pollTask = nil
        let tries = pauses.isEmpty ? [0] : pauses
        for pause in tries {
            if pause > 0 {
                try? await Task.sleep(nanoseconds: Self.nanos(pause))
            }
            guard recoveryLive(generation, epoch) else { return }
            let reached = await probe(epoch: epoch)
            guard recoveryLive(generation, epoch) else { return }
            if reached {
                await reloadVisible(epoch: epoch)
                guard recoveryLive(generation, epoch) else { return }
                if lastErrorKind != .network { break }
            }
        }
        guard recoveryLive(generation, epoch) else { return }
        beginPolling(resetState: false)
    }

    private func recoveryLive(_ generation: Int, _ epoch: Int) -> Bool {
        !Task.isCancelled && generation == recoveryGeneration && epoch == playerEpoch
    }

    /// One `/Status`. Does not send volume, transport, or queue commands when it fails.
    private func probe(epoch: Int) async -> Bool {
        guard epoch == playerEpoch, !host.isEmpty else { return false }
        do {
            let fresh = try await client.status(timeout: nil, etag: nil)
            guard recoveryProbeCurrent(epoch) else { return false }
            apply(fresh)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard recoveryProbeCurrent(epoch) else { return false }
            show(error)
            return false
        }
    }

    private func recoveryProbeCurrent(_ epoch: Int) -> Bool {
        epoch == playerEpoch && !Task.isCancelled
    }

    private func reloadVisible(epoch: Int) async {
        guard epoch == playerEpoch, !Task.isCancelled, !host.isEmpty else { return }
        switch ShellUI.shared.section {
        case .queue:
            await reloadQueue(epoch: epoch)
        case .library:
            await LibraryUI.shared.reloadAfterReconnect(self)
        case .playlists:
            await PlaylistUI.shared.reload(self)
        case .now:
            break
        }
    }

    private static func nanos(_ seconds: TimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    private static func noticeText(_ event: SleepFadeEvent) -> String {
        switch event {
        case .fading: return "Sleep: fading out…"
        case .paused(let restored): return restored ? "Sleep: paused, volume restored" : "Sleep: paused"
        case .stopped(let restored): return restored ? "Sleep: stopped, volume restored" : "Sleep: stopped"
        case .cancelled(let restored):
            return restored ? "Sleep: fade cancelled, volume restored" : "Sleep: fade cancelled"
        case .failed(let message): return message
        }
    }
}

enum ShownErrorKind {
    case network
    case other
}

/// Pause after wake, then one status read per entry. Defaults: 1.5 s, then three tries across about 6 s.
struct NetworkRecoveryTiming: Equatable, Sendable {
    var settle: TimeInterval = 1.5
    var pauses: [TimeInterval] = [0, 2, 2]
}

/// Where a seek was dropped, until `/Status` reports that place.
/// A poll that left earlier still carries the old second and must not win.
struct SeekLatch: Equatable {
    var target: Int
    var anchor: Int
    var askedAt: Date
    var until: Date

    func confirms(_ reported: Int, now: Date) -> Bool {
        let elapsed = max(0, Int(now.timeIntervalSince(askedAt).rounded(.down)))
        let anchorNow = anchor + elapsed
        let targetNow = target + elapsed
        let toAnchor = abs(reported - anchorNow)
        let toTarget = abs(reported - targetNow)
        let toDrop = abs(reported - target)
        let nearest = min(toTarget, toDrop)
        guard nearest <= 2 else { return false }
        if target == anchor { return true }
        // A report that is still walking the pre-seek playhead is not confirmation,
        // even when the seek itself was only a second or two.
        if toAnchor < nearest { return false }
        if toAnchor == nearest && toDrop > 0 && reported != target { return false }
        return true
    }
}
