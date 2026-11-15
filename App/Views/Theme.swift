import OhmaiCore
import SwiftUI

/// ohmai's few brand and data colors in one place.
enum Theme {
    /// Brand: the app icon's amber on ink.
    static let ink = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x22 / 255)
    static let amber = Color(red: 0xF3 / 255, green: 0xC0 / 255, blue: 0x4F / 255)

    /// Status (reserved for meaning, never for data): an agent waiting on you.
    static let waiting = Color.orange
}

extension Agent {
    /// Categorical identity, in fixed order (claude, codex, pi). Validated for color-vision
    /// deficiency and contrast in light and dark with the dataviz palette checker; always shown
    /// next to the agent's name, never as the only cue.
    var color: Color {
        switch self {
        case .claude: Color(light: 0x2A78D6, dark: 0x3987E5)  // blue
        case .codex: Color(light: 0xEB6834, dark: 0xD95926)   // orange
        case .pi: Color(light: 0x1BAF7A, dark: 0x199E70)      // aqua
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        })
    }
}
