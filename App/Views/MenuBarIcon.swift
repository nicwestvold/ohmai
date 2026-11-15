import AppKit
import SwiftUI

/// The Ω face in the menu bar: four glanceable states, drawn as template images so macOS
/// tints them for light and dark menu bars. Artwork: scripts/make-icons.py.
struct MenuBarIcon: View {
    let state: MenuBarIconState

    var body: some View {
        Image(nsImage: Self.image(state.assetName))
            .accessibilityLabel(state.label)
    }

    /// Menu bar labels ignore SwiftUI sizing, so size the NSImage itself.
    static func image(_ name: String, points: CGFloat = 18) -> NSImage {
        guard let source = NSImage(named: name), let image = source.copy() as? NSImage else { return NSImage() }
        image.size = NSSize(width: points, height: points)
        image.isTemplate = true
        return image
    }
}

extension MenuBarIconState {
    var assetName: String {
        switch self {
        case .asleep: "Face-asleep"
        case .working: "Face-working"
        case .waiting: "Face-waiting"
        case .shades: "Face-shades"
        }
    }

    var label: String {
        switch self {
        case .asleep: "ohmai: no agents running"
        case .working: "ohmai: agent working"
        case .waiting: "ohmai: agent waiting on you"
        case .shades: "ohmai: working with the lid closed"
        }
    }
}

/// The dropdown header's fuller set of expressions.
enum HeaderFace: Equatable {
    case asleep, focused, oh, shades, drowsy

    var assetName: String {
        switch self {
        case .asleep: "Face-header-asleep"
        case .focused: "Face-header-focused"
        case .oh: "Face-header-oh"
        case .shades: "Face-shades"
        case .drowsy: "Face-header-drowsy"
        }
    }
}

struct HeaderFaceView: View {
    let face: HeaderFace

    var body: some View {
        Image(face.assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)
    }
}
