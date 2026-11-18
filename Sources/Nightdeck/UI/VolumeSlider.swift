import AppKit
import NightdeckCore
import SwiftUI

private enum VolumeDrag {
    case began, changed, ended, cancelled
}

/// One mouse-wheel line is one volume step. Trackpad points accumulate, and a
/// burst commits at most once per `interval` so a swipe does not flood /Volume.
struct VolumeScroll: Equatable {
    static let pointsPerStep = 10.0
    static let interval: Duration = .milliseconds(140)

    private(set) var residue = 0.0
    private(set) var pending: Int?
    private var lastCommit: ContinuousClock.Instant?

    /// Positive `deltaY` is louder. `level` is the level already showing.
    mutating func note(deltaY: Double, precise: Bool, level: Int) {
        guard deltaY.isFinite, deltaY != 0 else { return }
        residue += precise ? deltaY / Self.pointsPerStep : deltaY
        let steps = Int(residue.rounded(.towardZero))
        guard steps != 0 else { return }
        residue -= Double(steps)
        let base = pending ?? level
        let next = min(100, max(0, base + steps))
        guard next != base else {
            residue = 0
            return
        }
        pending = next
    }

    /// The absolute level to commit, or nil while the interval is still open.
    /// `flush` sends a leftover change when the gesture ends or the quiet timer fires.
    mutating func take(now: ContinuousClock.Instant, flush: Bool) -> Int? {
        guard let pending else { return nil }
        if !flush, let lastCommit, lastCommit.duration(to: now) < Self.interval {
            return nil
        }
        self.pending = nil
        lastCommit = now
        return pending
    }

    mutating func cancel() {
        residue = 0
        pending = nil
    }
}

/// Fader proportions. The window track grows with the slot beside the titles.
/// The menu bar stays on a short cap. The column is the fader plus one readout.
enum VolumeForm {
    static let menuTrack: CGFloat = 112
    /// The titles-plus-controls slot stays under this. It only stops a bad proposal.
    static let windowTrackCap: CGFloat = 520
    static let readout: CGFloat = 18
    static let mute: CGFloat = 34
    /// Wide enough for one line, for example "40 · -40 dB".
    static let readoutWidth: CGFloat = 108

    struct Metrics: Equatable {
        var trackWidth: CGFloat
        var thumbWidth: CGFloat
        var thumbHeight: CGFloat
        var hitWidth: CGFloat
        var trackHeight: CGFloat
        var spacing: CGFloat
        var column: CGFloat
        var chrome: CGFloat
    }

    static func metrics(compact: Bool, span: CGFloat, columnLimit: CGFloat = .greatestFiniteMagnitude) -> Metrics {
        let spacing: CGFloat = compact ? 4 : 8
        let trackWidth: CGFloat = compact ? 16 : 30
        let thumbWidth: CGFloat = compact ? 22 : 44
        let thumbHeight: CGFloat = compact ? 4 : 9
        let hitWidth = thumbWidth + (compact ? 4 : 8)
        let chrome = spacing * 2 + readout + mute
        let cap = compact ? menuTrack : windowTrackCap
        let track = min(cap, max(0, span - chrome))
        var metrics = Metrics(
            trackWidth: trackWidth,
            thumbWidth: thumbWidth,
            thumbHeight: thumbHeight,
            hitWidth: hitWidth,
            trackHeight: track,
            spacing: spacing,
            column: max(hitWidth, readoutWidth),
            chrome: chrome
        )
        guard metrics.column > columnLimit, columnLimit > 48 else { return metrics }
        let scale = columnLimit / metrics.column
        metrics.trackWidth = max(10, metrics.trackWidth * scale)
        metrics.thumbWidth = max(metrics.trackWidth + 4, metrics.thumbWidth * scale)
        metrics.thumbHeight = max(3, metrics.thumbHeight * scale)
        metrics.hitWidth = max(metrics.thumbWidth, metrics.hitWidth * scale)
        metrics.column = columnLimit
        return metrics
    }
}

/// Vertical fader. Level changes commit on mouse-up, or on a scroll/key event.
/// Nothing here runs from layout or from a status refresh.
/// `span` is the height from the top of the titles through the transport row.
/// The menu bar leaves `span` open and uses the cap.
struct VolumeBlock: View {
    var status: PlayerStatus
    var connected: Bool
    var compact = false
    var span: CGFloat = 10_000
    var columnLimit: CGFloat = .greatestFiniteMagnitude
    @Environment(AppModel.self) private var model

    var body: some View {
        let metrics = VolumeForm.metrics(compact: compact, span: span, columnLimit: columnLimit)
        let shown = shownLevel
        VStack(spacing: metrics.spacing) {
            faderRow(metrics, shown: shown)
            Text(readout)
                .font(.caption.monospacedDigit())
                .foregroundStyle(enabled ? Theme.fader : Theme.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity)
                .frame(height: VolumeForm.readout)
            SymbolButton(
                systemName: status.mute ? DeckSymbol.muted : DeckSymbol.volume,
                help: status.mute ? "Unmute" : "Mute",
                active: status.mute,
                enabled: enabled,
                action: model.toggleMute
            )
            .frame(height: VolumeForm.mute)
        }
        .frame(width: metrics.column, alignment: .top)
        .onDisappear {
            // The menu-bar fader and the window fader share one drag flag.
            // Disappearing while the other surface is tracking must not cancel that drag or skip /Volume.
            if VolumeHitView.dragActive { return }
            let ui = TransportUI.shared
            guard ui.adjustingVolume else { return }
            ui.adjustingVolume = false
            ui.volumeBaseline = nil
            ui.volumeHost = ""
            ui.volumePort = 0
        }
    }

    private func faderRow(_ metrics: VolumeForm.Metrics, shown: Double) -> some View {
        VolumeTrack(
            fraction: shown / 100,
            live: enabled,
            thumbWidth: metrics.thumbWidth,
            thumbHeight: metrics.thumbHeight
        )
        .allowsHitTesting(false)
        .frame(width: metrics.trackWidth, height: metrics.trackHeight)
        .frame(width: metrics.hitWidth, height: metrics.trackHeight, alignment: .center)
        .overlay {
            VolumeInteraction(
                enabled: enabled,
                level: shownLevelInt,
                host: model.host,
                port: model.port,
                onDrag: drag,
                onSet: apply
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue(readout)
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? 1 : -1)
        }
    }

    private var fixed: Bool { status.volume < 0 }
    private var enabled: Bool { connected && !fixed }

    private var shownLevel: Double {
        let ui = TransportUI.shared
        if ui.adjustingVolume { return min(100, max(0, ui.volume)) }
        return Double(max(status.volume, 0))
    }

    private var shownLevelInt: Int { Int(shownLevel.rounded()) }

    private var readout: String {
        if fixed { return "Fixed" }
        let ui = TransportUI.shared
        if ui.adjustingVolume { return "\(Int(ui.volume.rounded()))%" }
        let level = max(status.volume, 0)
        guard !status.db.isEmpty else { return "\(level)%" }
        let db = status.db.lowercased().contains("db") ? status.db : "\(status.db) dB"
        return "\(level) · \(db)"
    }

    private func drag(_ phase: VolumeDrag, _ fraction: Double) {
        let ui = TransportUI.shared
        let level = Int((min(1, max(0, fraction)) * 100).rounded())
        switch phase {
        case .began:
            guard enabled else { return }
            ui.adjustingVolume = true
            ui.volume = Double(level)
            ui.volumeBaseline = status.volume
            ui.volumeHost = model.host
            ui.volumePort = model.port
        case .changed:
            guard ui.volumeBaseline != nil else { return }
            ui.adjustingVolume = true
            ui.volume = Double(level)
        case .ended:
            let baseline = ui.volumeBaseline
            let host = ui.volumeHost
            let port = ui.volumePort
            ui.volume = Double(level)
            ui.adjustingVolume = false
            ui.volumeBaseline = nil
            ui.volumeHost = ""
            ui.volumePort = 0
            // A sibling view may have cleared the shared flag. Commit from the level
            // captured at drag start, and never send to a player selected mid-drag.
            guard let baseline, model.host == host, model.port == port else { return }
            commit(level, comparedTo: baseline)
        case .cancelled:
            ui.adjustingVolume = false
            ui.volumeBaseline = nil
            ui.volumeHost = ""
            ui.volumePort = 0
        }
    }

    /// Arrow keys commit at once. During a drag they only move the thumb; mouse-up sends once.
    private func nudge(_ delta: Int) {
        guard enabled, delta != 0 else { return }
        let ui = TransportUI.shared
        if ui.adjustingVolume {
            ui.volume = min(100, max(0, ui.volume + Double(delta)))
            return
        }
        commit(min(100, max(0, status.volume + delta)))
    }

    private func apply(_ level: Int) {
        guard enabled else { return }
        let ui = TransportUI.shared
        if ui.adjustingVolume {
            ui.volume = Double(min(100, max(0, level)))
            return
        }
        commit(level)
    }

    /// `comparedTo` is the level at mouse-down. Scroll and keys compare with the
    /// status line, which is still the player level until this commit.
    private func commit(_ level: Int, comparedTo baseline: Int? = nil) {
        guard enabled else { return }
        guard level != (baseline ?? status.volume) else { return }
        model.setVolume(level)
    }
}

private struct VolumeTrack: View {
    var fraction: Double
    var live: Bool
    var thumbWidth: CGFloat
    var thumbHeight: CGFloat

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let clamped = min(1, max(0, fraction))
            let fill = height * clamped
            let travel = max(0, height - thumbHeight)
            let lift = min(travel, max(0, fill - thumbHeight / 2))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color(white: 0.14))
                Capsule()
                    .fill(Theme.fader)
                    .frame(width: width, height: max(0, fill))
            }
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.fader.opacity(live ? 0.9 : 0.28), lineWidth: 1.5))
            .overlay(alignment: .bottom) {
                RoundedRectangle(cornerRadius: thumbHeight / 2, style: .continuous)
                    .fill(Color.white.opacity(0.96))
                    .overlay {
                        Capsule().stroke(Color.black.opacity(0.4), lineWidth: 0.75)
                    }
                    .overlay {
                        Capsule()
                            .fill(Color.black.opacity(0.45))
                            .frame(width: thumbWidth * 0.46, height: 1)
                    }
                    .frame(width: thumbWidth, height: thumbHeight)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(y: -lift)
            }
        }
        .opacity(live ? 1 : 0.4)
    }
}

private struct VolumeInteraction: NSViewRepresentable {
    var enabled: Bool
    var level: Int
    var host: String
    var port: Int
    var onDrag: @MainActor (VolumeDrag, Double) -> Void
    var onSet: @MainActor (Int) -> Void

    func makeCoordinator() -> Sink {
        Sink(onDrag: onDrag, onSet: onSet)
    }

    func makeNSView(context: Context) -> VolumeHitView {
        let view = VolumeHitView()
        view.sink = context.coordinator
        return view
    }

    func updateNSView(_ view: VolumeHitView, context: Context) {
        let sink = context.coordinator
        sink.enabled = enabled
        sink.host = host
        sink.port = port
        if sink.scroll.pending == nil, !sink.dragging {
            sink.level = level
        }
        sink.onDrag = onDrag
        sink.onSet = onSet
        view.sink = sink
        view.toolTip = "Volume"
    }

    final class Sink {
        var enabled = false
        var dragging = false
        var level = 0
        var host = ""
        var port = 0
        var flushGen = 0
        var scroll = VolumeScroll()
        var onDrag: @MainActor (VolumeDrag, Double) -> Void
        var onSet: @MainActor (Int) -> Void

        init(onDrag: @escaping @MainActor (VolumeDrag, Double) -> Void, onSet: @escaping @MainActor (Int) -> Void) {
            self.onDrag = onDrag
            self.onSet = onSet
        }
    }
}

final class VolumeHitView: NSView {
    /// True while a fader is inside its tracking loop. Shared by both faders.
    static var dragActive = false
    /// Tests set this so mouse-up clears the shared flag before commit, the way a disappearing sibling used to.
    static var clearSharedFlagBeforeEnd = false
    /// Keeps the fader alive if SwiftUI removes it before mouse-up.
    private static var tracking: VolumeHitView?
    private var dragMonitor: Any?
    fileprivate var sink: VolumeInteraction.Sink?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { return nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { sink?.enabled ?? false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let sink, sink.enabled else { return }
        window?.makeFirstResponder(self)
        sink.dragging = true
        Self.dragActive = true
        Self.tracking = self
        sink.scroll.cancel()
        send(.began, event)
        // A parent can swallow mouse-up after this view is removed. The monitor still sees it.
        removeDragMonitor()
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] incoming in
            guard let self, let sink = self.sink, sink.dragging else { return incoming }
            if let eventWindow = incoming.window, eventWindow !== self.window { return incoming }
            if incoming.type == .leftMouseUp {
                self.finishDrag(with: incoming)
            } else if sink.enabled {
                self.send(.changed, incoming)
            }
            return incoming
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let sink, sink.dragging, sink.enabled else { return }
        send(.changed, event)
    }

    override func mouseUp(with event: NSEvent) {
        finishDrag(with: event)
    }

    private func finishDrag(with event: NSEvent) {
        guard let sink, sink.dragging else { return }
        sink.dragging = false
        Self.dragActive = false
        removeDragMonitor()
        send(sink.enabled ? .ended : .cancelled, event)
        if Self.tracking === self { Self.tracking = nil }
    }

    private func removeDragMonitor() {
        if let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let sink, sink.enabled, !sink.dragging else {
            super.scrollWheel(with: event)
            return
        }
        sink.scroll.note(
            deltaY: Double(event.scrollingDeltaY),
            precise: event.hasPreciseScrollingDeltas,
            level: sink.level
        )
        let ended = event.phase == .ended || event.phase == .cancelled
            || event.momentumPhase == .ended || event.momentumPhase == .cancelled
        applyScroll(flush: ended)
        if sink.scroll.pending != nil {
            armFlush()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let sink, sink.enabled else {
            super.keyDown(with: event)
            return
        }
        let step = event.modifierFlags.contains(.shift) ? 5 : 1
        let delta: Int
        switch event.specialKey {
        case .upArrow, .rightArrow: delta = step
        case .downArrow, .leftArrow: delta = -step
        default:
            super.keyDown(with: event)
            return
        }
        let next = min(100, max(0, sink.level + delta))
        sink.level = next
        deliver { $0.onSet(next) }
    }

    private func applyScroll(flush: Bool) {
        guard let sink, sink.enabled else {
            sink?.scroll.cancel()
            return
        }
        guard let next = sink.scroll.take(now: .now, flush: flush), next != sink.level else { return }
        sink.level = next
        deliver { $0.onSet(next) }
    }

    private func armFlush() {
        guard let sink else { return }
        sink.flushGen += 1
        let generation = sink.flushGen
        let host = sink.host
        let port = sink.port
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: VolumeScroll.interval)
            guard let self, let sink = self.sink, sink.flushGen == generation else { return }
            guard sink.host == host, sink.port == port else {
                sink.scroll.cancel()
                return
            }
            self.applyScroll(flush: true)
        }
    }

    private func send(_ phase: VolumeDrag, _ event: NSEvent) {
        let fraction = fraction(of: event)
        deliver { sink in
            if phase == .ended, VolumeHitView.clearSharedFlagBeforeEnd {
                TransportUI.shared.adjustingVolume = false
            }
            sink.onDrag(phase, fraction)
        }
        if phase == .ended {
            sink?.level = Int((min(1, max(0, fraction)) * 100).rounded())
        }
    }

    private func deliver(_ body: @escaping @MainActor (VolumeInteraction.Sink) -> Void) {
        guard let sink else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(sink) }
        } else {
            Task { @MainActor in body(sink) }
        }
    }

    private func fraction(of event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        let height = bounds.height
        guard height > 0 else { return 0 }
        let unit = point.y / height
        return min(1, max(0, isFlipped ? 1 - unit : unit))
    }
}
