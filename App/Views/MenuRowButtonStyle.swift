import SwiftUI

/// A full-width menu row that highlights on hover and press, like a native menu item.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill)
                }
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.08), value: hovering)
        }

        private var fill: AnyShapeStyle {
            if configuration.isPressed { return AnyShapeStyle(.quaternary.opacity(1.6)) }
            if hovering { return AnyShapeStyle(.quaternary) }
            return AnyShapeStyle(.clear)
        }
    }
}

/// A menu row's label: title on the left, keyboard shortcut hint on the right.
struct MenuRowLabel: View {
    let title: String
    var systemImage: String?
    var shortcut: String?

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
            }
            Text(title)
            Spacer(minLength: 12)
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
