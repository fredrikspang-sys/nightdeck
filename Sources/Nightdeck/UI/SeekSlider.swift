import AppKit
import NightdeckCore
import SwiftUI

private enum SeekDrag {
    case began, changed, ended, cancelled
}

/// Scrubber proportions. The track is a thick capsule; the knob is a vertical pill on it.
enum SeekForm {
    static let trackHeight: CGFloat = 10
    static let knobWidth: CGFloat = 14
    static let knobHeight: CGFloat = 26
    static let hitHeight: CGFloat = 32
}

/// Horizontal playhead. A click or drag moves the knob immediately.
/// `/Play?seek` goes out on mouse-up, once. The clock ticks beside this view,
/// so a refresh cannot tear down the drag.
struct SeekBlock: View {
    var status: PlayerStatus
    var connected: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            scrubber
            times
        }
        .onDisappear {
            // Mouse-up still sends. A timeline tick must not cancel the scrub.
            if SeekHitView.dragActive { return }
            let ui = TransportUI.shared
            guard ui.seeking || ui.seekBaseline != nil else { return }
            ui.seeking = false
            ui.seekBaseline = nil
            ui.seekHost = ""
            ui.seekPort = 0
            ui.seekHover = nil
        }
    }

    private var canScrub: Bool { connected && status.seekable }

    /// The knob shows the drag, not the poll, for as long as the mouse is down.
    private func shownSeconds(at date: Date) -> Double {
        let ui = TransportUI.shared
        if ui.seeking { return ui.seek }
        return model.elapsed(at: date)
    }

    private var tipSeconds: Double? {
        let ui = TransportUI.shared
        if ui.seeking { return ui.seek }
        return ui.seekHover
    }

    private var showUnseekable: Bool {
        guard connected, !status.seekable else { return false }
        return !status.title.isEmpty || status.song >= 0 || status.total > 0
    }

    private var scrubber: some View {
        let tip = tipSeconds
        return GeometryReader { geo in
            ZStack {
                playhead
                    .allowsHitTesting(false)
                SeekInteraction(
                    enabled: canScrub,
                    total: status.total,
                    host: model.host,
                    port: model.port,
                    caption: scrubCaption(tip),
                    onDrag: { phase, seconds in drag(phase, seconds) },
                    onHover: { TransportUI.shared.seekHover = $0 },
                    onNudge: { nudge($0) }
                )
                if let tip, status.total > 0 {
                    tooltip(tip, width: geo.size.width)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .frame(height: SeekForm.hitHeight)
        .accessibilityLabel("Seek")
        .accessibilityValue(canScrub ? Clock.text(shownSeconds(at: Date())) : (showUnseekable ? "Can't seek this stream" : Clock.text(shownSeconds(at: Date()))))
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? 5 : -5)
        }
    }

    /// The hit view stays outside this clock. A tick redraws the knob and does not rebuild the drag.
    @ViewBuilder private var playhead: some View {
        if status.state.isPlaying {
            TimelineView(.periodic(from: status.receivedAt, by: 0.5)) { context in
                SeekTrack(fraction: fraction(for: shownSeconds(at: context.date)), live: canScrub)
            }
        } else {
            SeekTrack(fraction: fraction(for: shownSeconds(at: Date())), live: canScrub)
        }
    }

    private func tooltip(_ seconds: Double, width: CGFloat) -> some View {
        let label = Clock.text(seconds)
        let total = Double(max(status.total, 1))
        let center = min(1, max(0, seconds / total)) * width
        let x = min(max(0, width - 52), max(0, center - 26))
        return Text(label)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4).stroke(Theme.accent.opacity(0.55), lineWidth: 1)
            }
            .fixedSize()
            .offset(x: x, y: -18)
            .allowsHitTesting(false)
            .accessibilityLabel("Seek position \(label)")
    }

    private var times: some View {
        Group {
            if status.state.isPlaying {
                TimelineView(.periodic(from: status.receivedAt, by: 0.5)) { context in
                    timeRow(shownSeconds(at: context.date))
                }
            } else {
                timeRow(shownSeconds(at: Date()))
            }
        }
    }

    private func timeRow(_ shown: Double) -> some View {
        HStack(spacing: 8) {
            Text(Clock.text(shown))
            Spacer(minLength: 8)
            if showUnseekable {
                Text("Can't seek this stream")
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(status.total > 0 ? Clock.text(Double(status.total)) : "—")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Theme.tertiary)
    }

    private func scrubCaption(_ tip: Double?) -> String {
        if let tip, canScrub || TransportUI.shared.seeking { return "Seek position \(Clock.text(tip))" }
        if showUnseekable { return "Can't seek this stream" }
        return "Seek"
    }

    private func fraction(for seconds: Double) -> Double {
        guard status.total > 0 else { return 0 }
        return min(1, max(0, seconds / Double(status.total)))
    }

    private func drag(_ phase: SeekDrag, _ seconds: Double) {
        let ui = TransportUI.shared
        switch phase {
        case .began:
            guard canScrub else { return }
            ui.seeking = true
            ui.seek = seconds
            ui.seekBaseline = model.elapsed()
            ui.seekHost = model.host
            ui.seekPort = model.port
        case .changed:
            guard ui.seekBaseline != nil else { return }
            ui.seeking = true
            ui.seek = seconds
        case .ended:
            let baseline = ui.seekBaseline
            let host = ui.seekHost
            let port = ui.seekPort
            ui.seek = seconds
            ui.seeking = false
            ui.seekBaseline = nil
            ui.seekHost = ""
            ui.seekPort = 0
            ui.seekHover = nil
            // A disappearing sibling can clear the shared flag before mouse-up.
            // The second captured at mouse-down is what decides whether this was a move.
            guard let baseline, model.host == host, model.port == port else { return }
            guard Int(seconds.rounded()) != Int(baseline.rounded()) else { return }
            model.seek(to: seconds)
        case .cancelled:
            ui.seeking = false
            ui.seekBaseline = nil
            ui.seekHost = ""
            ui.seekPort = 0
            ui.seekHover = nil
        }
    }

    /// Arrow keys commit at once. During a drag they only move the knob.
    private func nudge(_ delta: Double) {
        guard canScrub, delta != 0 else { return }
        let ui = TransportUI.shared
        let upper = Double(max(status.total, 0))
        if ui.seeking {
            ui.seek = min(upper, max(0, ui.seek + delta))
            return
        }
        let target = min(upper, max(0, model.elapsed() + delta))
        guard Int(target.rounded()) != Int(model.elapsed().rounded()) else { return }
        model.seek(to: target)
    }
}

private struct SeekTrack: View {
    var fraction: Double
    var live: Bool

    var body: some View {
        GeometryReader { geo in
            let width = max(0, geo.size.width)
            let clamped = min(1, max(0, fraction))
            let travel = max(0, width - SeekForm.knobWidth)
            let knobX = travel * clamped
            let fill = width * clamped
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(white: 0.14))
                    .frame(height: SeekForm.trackHeight)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(0, fill), height: SeekForm.trackHeight)
                    }
                    .clipShape(Capsule())
                    .overlay {
                        Capsule().stroke(Theme.accent.opacity(live ? 0.9 : 0.28), lineWidth: 1.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                RoundedRectangle(cornerRadius: SeekForm.knobWidth / 2, style: .continuous)
                    .fill(Color.white.opacity(live ? 0.96 : 0.55))
                    .overlay {
                        Capsule().stroke(Color.black.opacity(0.4), lineWidth: 0.75)
                    }
                    .overlay {
                        Capsule()
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 1, height: SeekForm.knobHeight * 0.46)
                    }
                    .frame(width: SeekForm.knobWidth, height: SeekForm.knobHeight)
                    .shadow(color: .black.opacity(live ? 0.35 : 0), radius: 1, y: 0.5)
                    .offset(x: knobX)
            }
        }
        .opacity(live ? 1 : 0.4)
    }
}

private struct SeekInteraction: NSViewRepresentable {
    var enabled: Bool
    var total: Int
    var host: String
    var port: Int
    var caption: String
    var onDrag: @MainActor (SeekDrag, Double) -> Void
    var onHover: @MainActor (Double?) -> Void
    var onNudge: @MainActor (Double) -> Void

    func makeCoordinator() -> Sink {
        Sink(onDrag: onDrag, onHover: onHover, onNudge: onNudge)
    }

    func makeNSView(context: Context) -> SeekHitView {
        let view = SeekHitView()
        view.sink = context.coordinator
        return view
    }

    func updateNSView(_ view: SeekHitView, context: Context) {
        let sink = context.coordinator
        sink.enabled = enabled
        sink.total = total
        sink.host = host
        sink.port = port
        sink.caption = caption
        sink.onDrag = onDrag
        sink.onHover = onHover
        sink.onNudge = onNudge
        view.sink = sink
        if !sink.dragging {
            view.toolTip = caption
            view.setAccessibilityLabel(caption)
        }
    }

    final class Sink {
        var enabled = false
        var dragging = false
        var total = 0
        var host = ""
        var port = 0
        var caption = "Seek"
        var onDrag: @MainActor (SeekDrag, Double) -> Void
        var onHover: @MainActor (Double?) -> Void
        var onNudge: @MainActor (Double) -> Void

        init(
            onDrag: @escaping @MainActor (SeekDrag, Double) -> Void,
            onHover: @escaping @MainActor (Double?) -> Void,
            onNudge: @escaping @MainActor (Double) -> Void
        ) {
            self.onDrag = onDrag
            self.onHover = onHover
            self.onNudge = onNudge
        }

        func seconds(for fraction: Double) -> Double {
            let span = Double(max(total, 0))
            return min(span, max(0, fraction)) * span
        }
    }
}

final class SeekHitView: NSView {
    /// True while a scrubber is inside its tracking loop.
    static var dragActive = false
    /// Tests clear the shared flag before mouse-up, the way a rebuilt slider used to.
    static var clearSharedFlagBeforeEnd = false
    private static var tracking: SeekHitView?
    private var dragMonitor: Any?
    private var hoverArea: NSTrackingArea?
    fileprivate var sink: SeekInteraction.Sink?

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseDown(with event: NSEvent) {
        guard let sink, sink.enabled else { return }
        window?.makeFirstResponder(self)
        sink.dragging = true
        Self.dragActive = true
        Self.tracking = self
        send(.began, event)
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

    override func mouseEntered(with event: NSEvent) { reportHover(event) }
    override func mouseMoved(with event: NSEvent) { reportHover(event) }

    override func mouseExited(with event: NSEvent) {
        guard sink?.dragging != true else { return }
        deliver { $0.onHover(nil) }
    }

    override func keyDown(with event: NSEvent) {
        guard let sink, sink.enabled else {
            super.keyDown(with: event)
            return
        }
        let step = event.modifierFlags.contains(.shift) ? 15.0 : 5.0
        let delta: Double
        switch event.specialKey {
        case .rightArrow, .upArrow: delta = step
        case .leftArrow, .downArrow: delta = -step
        default:
            super.keyDown(with: event)
            return
        }
        deliver { $0.onNudge(delta) }
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

    private func reportHover(_ event: NSEvent) {
        guard let sink, sink.enabled, sink.total > 0, !sink.dragging else { return }
        let seconds = sink.seconds(for: fraction(of: event))
        deliver { $0.onHover(seconds) }
    }

    private func send(_ phase: SeekDrag, _ event: NSEvent) {
        guard let sink else { return }
        let seconds = sink.seconds(for: fraction(of: event))
        if sink.enabled {
            toolTip = "Seek position \(Clock.text(seconds))"
            setAccessibilityValue(Clock.text(seconds))
        }
        deliver { sink in
            if phase == .ended, SeekHitView.clearSharedFlagBeforeEnd {
                TransportUI.shared.seeking = false
            }
            sink.onDrag(phase, seconds)
        }
    }

    private func deliver(_ body: @escaping @MainActor (SeekInteraction.Sink) -> Void) {
        guard let sink else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(sink) }
        } else {
            Task { @MainActor in body(sink) }
        }
    }

    private func fraction(of event: NSEvent) -> Double {
        let point = convert(event.locationInWindow, from: nil)
        let width = bounds.width
        guard width > 0 else { return 0 }
        return min(1, max(0, point.x / width))
    }
}
