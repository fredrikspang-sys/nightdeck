import SwiftUI

/// SF Symbols for the IEC 60417 transport marks.
/// Previous and next are the bar-and-triangle pair, not the seek doubles.
enum DeckSymbol {
    static let play = "play.fill"
    static let pause = "pause.fill"
    static let stop = "stop.fill"
    static let previous = "backward.end.fill"
    static let next = "forward.end.fill"
    static let shuffle = "shuffle"
    static let repeatAll = "repeat"
    static let repeatOne = "repeat.1"
    static let volume = "speaker.wave.2.fill"
    static let muted = "speaker.slash.fill"
    static let sleep = "moon.fill"
    static let refresh = "arrow.clockwise"
    static let clear = "trash"
    static let remove = "minus.circle"
    static let up = "chevron.up"
    static let down = "chevron.down"
    static let back = "chevron.left"
    static let search = "magnifyingglass"
    static let add = "plus"
    static let added = "checkmark"
    static let delete = "trash"
    static let save = "square.and.arrow.down"
}

enum DeckIconScale {
    /// Main transport cluster.
    case transport
    /// Shuffle, queue, library, and the other controls.
    case control

    fileprivate var font: Font { self == .transport ? .title2 : .body }
    fileprivate var width: CGFloat { self == .transport ? 44 : 28 }
    fileprivate var height: CGFloat { self == .transport ? 36 : 28 }
}

/// Icon button. `help` is the old title, used as the tooltip and the accessibility label.
struct SymbolButton: View {
    var systemName: String
    var help: String
    var caption: String? = nil
    var scale: DeckIconScale = .control
    var active = false
    var prominent = false
    var bordered = false
    var destructive = false
    var enabled = true
    var action: () -> Void

    var body: some View {
        Group {
            if bordered {
                button.buttonStyle(.bordered)
            } else {
                button.buttonStyle(.borderless)
            }
        }
        .modifier(SymbolTint(active: active, prominent: prominent, destructive: destructive))
    }

    private var button: some View {
        Button(role: destructive ? ButtonRole.destructive : nil, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(scale.font.weight(active ? .semibold : .regular))
                if let caption {
                    Text(caption)
                        .font(.callout.monospacedDigit())
                        .lineLimit(1)
                }
            }
            .foregroundStyle(foreground)
            .frame(minWidth: scale.width, minHeight: scale.height)
            .padding(.horizontal, caption == nil ? 0 : 6)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.18))
                }
            }
            .contentShape(Rectangle())
        }
        .help(help)
        .accessibilityLabel(help)
        .disabled(!enabled)
    }

    private var foreground: Color {
        if active { return Theme.accent }
        if destructive { return Theme.danger }
        if prominent { return Theme.text }
        return Theme.secondary
    }
}

/// Active controls take the accent. Transport stays on the system color. The rest sit back.
private struct SymbolTint: ViewModifier {
    var active: Bool
    var prominent: Bool
    var destructive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.tint(Theme.accent)
        } else if destructive {
            content.tint(Theme.danger)
        } else if prominent {
            content
        } else {
            content.tint(Theme.secondary)
        }
    }
}
