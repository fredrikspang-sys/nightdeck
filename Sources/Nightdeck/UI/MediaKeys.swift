import Foundation
import MediaPlayer

/// Media keys and Control Center. Now Playing info is pushed when status changes; the system interpolates elapsed time.
@MainActor
final class MediaKeyController {
    private let model: AppModel
    private var started = false
    private var artworkPath = ""
    private var artworkGeneration = 0
    private let commands = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard !started else { return }
        started = true
        bind(commands.playCommand) { model in
            if !model.status.state.isPlaying { model.togglePlayPause() }
        }
        bind(commands.pauseCommand) { model in
            if model.status.state.isPlaying { model.togglePlayPause() }
        }
        bind(commands.togglePlayPauseCommand) { model in
            model.togglePlayPause()
        }
        bind(commands.nextTrackCommand) { model in model.next() }
        bind(commands.previousTrackCommand) { model in model.previous() }
        bind(commands.stopCommand) { model in model.stopPlayback() }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let seconds = position.positionTime
            Task { @MainActor in self?.model.seek(to: seconds) }
            return .success
        }
        sync()
    }

    func sync() {
        let status = model.status
        let connected = model.connected
        commands.playCommand.isEnabled = connected
        commands.pauseCommand.isEnabled = connected
        commands.togglePlayPauseCommand.isEnabled = connected
        commands.nextTrackCommand.isEnabled = connected
        commands.previousTrackCommand.isEnabled = connected
        commands.stopCommand.isEnabled = connected
        commands.changePlaybackPositionCommand.isEnabled = connected && status.seekable

        var payload: [String: Any] = [
            MPMediaItemPropertyTitle: status.title,
            MPMediaItemPropertyArtist: status.artist,
            MPMediaItemPropertyAlbumTitle: status.album,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: model.elapsed(),
            MPNowPlayingInfoPropertyPlaybackRate: status.state.isPlaying ? 1.0 : 0.0,
        ]
        if status.total > 0 {
            payload[MPMediaItemPropertyPlaybackDuration] = Double(status.total)
        }
        let path = status.imagePath
        if !path.isEmpty, let existing = info.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            payload[MPMediaItemPropertyArtwork] = existing
        }
        info.nowPlayingInfo = payload
        guard path != artworkPath else { return }
        artworkPath = path
        artworkGeneration += 1
        let generation = artworkGeneration
        guard !path.isEmpty else { return }
        Task { @MainActor in
            let image = await ArtCache.shared.image(for: path) { await self.model.artwork(path: $0) }
            guard !Task.isCancelled, generation == self.artworkGeneration, let image else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var next = self.info.nowPlayingInfo ?? [:]
            next[MPMediaItemPropertyArtwork] = artwork
            guard generation == self.artworkGeneration else { return }
            self.info.nowPlayingInfo = next
        }
    }

    private func bind(_ command: MPRemoteCommand, action: @escaping @MainActor (AppModel) -> Void) {
        command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                action(self.model)
            }
            return .success
        }
    }
}

enum PlaybackKeys {
    @MainActor static var controller: MediaKeyController?

    @MainActor static func attach(_ model: AppModel) {
        if controller == nil { controller = MediaKeyController(model: model) }
        controller?.start()
        controller?.sync()
    }

    @MainActor static func sync() {
        controller?.sync()
    }
}
