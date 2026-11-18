import AppKit
import NightdeckCore
import SwiftUI

@MainActor
@Observable
final class TransportUI {
    static let shared = TransportUI()
    var seeking = false
    var seek = 0.0
    var adjustingVolume = false
    var volume = 0.0
    var cover: NSImage?
    var coverPath = ""

    /// Level and player captured when a drag starts. Mouse-up compares against this,
    /// not against a volume the model may already have stored optimistically.
    var volumeBaseline: Int?
    var volumeHost = ""
    var volumePort = 0

    /// Playhead and player captured when a scrub starts. Mouse-up compares against this.
    var seekBaseline: Double?
    var seekHost = ""
    var seekPort = 0
    /// Time under the pointer. Nil when the pointer is elsewhere.
    var seekHover: Double?

    /// Drop a drag, a seek, and the previous player's cover. Does not send a command.
    func resetTransient() {
        seeking = false
        adjustingVolume = false
        volumeBaseline = nil
        volumeHost = ""
        volumePort = 0
        seekBaseline = nil
        seekHost = ""
        seekPort = 0
        seekHover = nil
        seek = 0
        volume = 0
        cover = nil
        coverPath = ""
    }
}

/// Banner, cover, titles, and the controls under the cover. The cover is at most 280 pt.
/// It shrinks when the column is short or narrow, and it does not grow to fill a tall window.
/// The fader is the fifth child. Its top lines up with the titles and its bottom with the controls.
private struct NowPlayingColumn: Layout {
    var spacing: CGFloat = 22
    var maxSide: CGFloat = 280
    var columnSpacing: CGFloat = 28
    var volumeGap: CGFloat = 16
    var minText: CGFloat = 168

    private struct Plan {
        var bannerH: CGFloat
        var side: CGFloat
        var textW: CGFloat
        var middle: CGFloat
        var tailW: CGFloat
        var tailH: CGFloat
        var volumeW: CGFloat
        var volumeH: CGFloat
        var yMiddle: CGFloat
        var yTail: CGFloat
        var total: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 5 else {
            return CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
        }
        let width = proposal.width ?? 860
        let offered = proposal.height.map { $0.isFinite ? $0 : maxSide + 400 } ?? (maxSide + 400)
        let plan = arrange(width: width, limit: offered, subviews: subviews)
        if let limit = proposal.height, limit.isFinite, limit < plan.total {
            return CGSize(width: width, height: limit)
        }
        return CGSize(width: width, height: plan.total)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 5, bounds.width > 1, bounds.height > 1 else { return }
        let plan = arrange(width: bounds.width, limit: bounds.height, subviews: subviews)
        let x = bounds.minX
        if plan.bannerH > 0.5 {
            subviews[0].place(
                at: CGPoint(x: x, y: bounds.minY),
                proposal: ProposedViewSize(width: bounds.width, height: plan.bannerH)
            )
        }
        let y = bounds.minY + plan.yMiddle
        subviews[1].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: plan.side, height: plan.side))
        subviews[2].place(
            at: CGPoint(x: x + plan.side + columnSpacing, y: y),
            proposal: ProposedViewSize(width: plan.textW, height: plan.middle)
        )
        subviews[3].place(
            at: CGPoint(x: x, y: bounds.minY + plan.yTail),
            proposal: ProposedViewSize(width: plan.tailW, height: plan.tailH)
        )
        subviews[4].place(
            at: CGPoint(x: bounds.maxX - plan.volumeW, y: y),
            proposal: ProposedViewSize(width: plan.volumeW, height: plan.volumeH)
        )
    }

    /// Two passes: the fader column depends on its height, and that height depends on the text width.
    private func arrange(width: CGFloat, limit: CGFloat, subviews: Subviews) -> Plan {
        let seed = VolumeForm.metrics(compact: false, span: VolumeForm.windowTrackCap).column
        let draft = measure(width: width, limit: limit, volumeW: seed, subviews: subviews)
        let fitted = VolumeForm.metrics(compact: false, span: draft.volumeH).column
        let second = measure(width: width, limit: limit, volumeW: fitted, subviews: subviews)
        let need = VolumeForm.metrics(compact: false, span: second.volumeH).column
        if need <= second.volumeW + 0.5 { return second }
        return measure(width: width, limit: limit, volumeW: need, subviews: subviews)
    }

    private func measure(width: CGFloat, limit: CGFloat, volumeW: CGFloat, subviews: Subviews) -> Plan {
        let bannerH = height(of: subviews[0], width: width)
        let tailW = max(0, width - volumeW - volumeGap)
        let tailH = height(of: subviews[3], width: tailW)
        let bannerGap: CGFloat = bannerH > 0.5 ? spacing : 0
        let room = max(0, limit - bannerH - bannerGap - spacing - tailH)
        let sideCap = max(0, tailW - columnSpacing - minText)
        let side = min(maxSide, room, sideCap)
        let textW = max(0, tailW - side - columnSpacing)
        let textH = height(of: subviews[2], width: max(textW, 1))
        // Titles taller than the cover still set the row. A short window clips them before the controls.
        let middle = min(room, max(side, textH))
        let yMiddle = bannerH + bannerGap
        let yTail = yMiddle + middle + spacing
        return Plan(
            bannerH: bannerH,
            side: side,
            textW: textW,
            middle: middle,
            tailW: tailW,
            tailH: tailH,
            volumeW: volumeW,
            volumeH: max(0, middle + spacing + tailH),
            yMiddle: yMiddle,
            yTail: yTail,
            total: yTail + tailH
        )
    }

    private func height(of subview: LayoutSubview, width: CGFloat) -> CGFloat {
        subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.status
        VStack(alignment: .leading, spacing: 22) {
            NowPlayingColumn {
                banner
                cover
                titles(status)
                tail(status)
                volumeSlot(status)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg)
        .foregroundStyle(Theme.text)
        .task(id: model.status.imagePath) {
            let path = model.status.imagePath
            let ui = TransportUI.shared
            guard path != ui.coverPath else { return }
            if path.isEmpty {
                ui.coverPath = ""
                ui.cover = nil
                return
            }
            ui.cover = nil
            let image = await ArtCache.shared.image(for: path) { await model.artwork(path: $0) }
            guard !Task.isCancelled, model.status.imagePath == path else { return }
            guard let image else { return }
            ui.coverPath = path
            ui.cover = image
        }
    }

    private var banner: some View {
        // VStack stays one layout child when the message is absent. Group would disappear.
        VStack(alignment: .leading, spacing: 0) {
            if model.host.isEmpty {
                Text("Choose a player")
                    .font(.callout)
                    .foregroundStyle(Theme.secondary)
            } else if !model.connected {
                Text(model.lastError ?? "Connecting to \(model.host)…")
                    .font(.callout)
                    .foregroundStyle(model.lastError == nil ? Theme.secondary : Theme.danger)
            } else if let error = model.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func titles(_ status: PlayerStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(status.title.isEmpty ? "Nothing playing" : status.title)
                .font(.system(size: 28, weight: .semibold))
                .lineLimit(2)
            Text([status.artist, status.album].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.title3)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
            if !model.groupCaption.isEmpty {
                Text(model.groupCaption)
                    .font(.callout)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(2)
                    .accessibilityLabel("Group \(model.groupCaption)")
            }
            if !status.formatText.isEmpty {
                Text(status.formatText)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            if status.indexing > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Indexing library…")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Indexing library")
            }
            if let caption = model.sleepCaption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
            }
        }
        .clipped()
    }

    private func tail(_ status: PlayerStatus) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            SeekBlock(status: status, connected: model.connected)
            transport(status)
            if let notice = model.notice {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(notice)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func transport(_ status: PlayerStatus) -> some View {
        HStack(spacing: 14) {
            SymbolButton(systemName: DeckSymbol.previous, help: "Previous", scale: .transport, prominent: true, bordered: true, enabled: model.connected, action: model.previous)
            SymbolButton(
                systemName: status.state.isPlaying ? DeckSymbol.pause : DeckSymbol.play,
                help: status.state.isPlaying ? "Pause" : "Play",
                scale: .transport,
                prominent: true,
                bordered: true,
                enabled: model.connected,
                action: model.togglePlayPause
            )
            SymbolButton(
                systemName: DeckSymbol.stop,
                help: "Stop",
                scale: .transport,
                prominent: true,
                bordered: true,
                enabled: model.connected && status.state != .stop,
                action: model.stopPlayback
            )
            SymbolButton(systemName: DeckSymbol.next, help: "Next", scale: .transport, prominent: true, bordered: true, enabled: model.connected, action: model.next)
            Spacer()
            SymbolButton(
                systemName: DeckSymbol.shuffle,
                help: status.shuffle ? "Shuffle on" : "Shuffle",
                active: status.shuffle,
                bordered: true,
                enabled: model.connected,
                action: model.toggleShuffle
            )
            SymbolButton(
                systemName: status.repeatMode == .track ? DeckSymbol.repeatOne : DeckSymbol.repeatAll,
                help: "Repeat \(status.repeatMode.label)",
                active: status.repeatMode == .queue || status.repeatMode == .track,
                bordered: true,
                enabled: model.connected,
                action: model.cycleRepeat
            )
            SymbolButton(
                systemName: DeckSymbol.sleep,
                help: status.sleepMinutes > 0 ? "Sleep \(status.sleepMinutes)m" : "Sleep",
                caption: status.sleepMinutes > 0 ? "\(status.sleepMinutes)m" : nil,
                active: status.sleepMinutes > 0,
                bordered: true,
                enabled: model.connected,
                action: model.cycleSleep
            )
        }
    }

    private var cover: some View {
        Group {
            if let image = TransportUI.shared.cover {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func volumeSlot(_ status: PlayerStatus) -> some View {
        GeometryReader { geo in
            VolumeBlock(
                status: status,
                connected: model.connected,
                span: geo.size.height,
                columnLimit: geo.size.width
            )
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
        }
    }
}

enum Clock {
    static func text(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
