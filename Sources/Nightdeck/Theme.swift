import SwiftUI

enum Theme {
    static let bg = Color(red: 0.07, green: 0.075, blue: 0.09)
    static let panel = Color(red: 0.12, green: 0.125, blue: 0.145)
    static let text = Color.white
    static let secondary = Color.white.opacity(0.64)
    static let tertiary = Color.white.opacity(0.40)
    static let accent = Color(red: 0.45, green: 0.70, blue: 0.98)
    /// Amber fader, distinct from the blue timeline.
    static let fader = Color(red: 0.95, green: 0.58, blue: 0.22)
    static let danger = Color(red: 0.93, green: 0.38, blue: 0.36)
}
