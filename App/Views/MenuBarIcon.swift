import SwiftUI

/// Placeholder glyphs until the Ω face artwork exists. The states already differ in shape,
/// as the design requires; swap these for template images of the face later.
struct MenuBarIcon: View {
    let state: MenuBarIconState

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(label)
    }

    private var symbol: String {
        switch state {
        case .asleep: "moon.zzz"
        case .working: "bolt.fill"
        case .waiting: "bolt.badge.clock.fill"
        case .shades: "eyeglasses"
        }
    }

    private var label: String {
        switch state {
        case .asleep: "ohmai: no agents running"
        case .working: "ohmai: agent working"
        case .waiting: "ohmai: agent waiting on you"
        case .shades: "ohmai: keeping Mac awake with the lid closed"
        }
    }
}
