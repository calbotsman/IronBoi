import SwiftUI

// Reusable Dossier-doctrine building blocks (MyoTheme v2). Selection is the
// coach's red pen / ochre; states use the semantic State roles. No system
// toggles, no form chrome. See docs/design/myo-living-dossier-art-direction.md.

/// Monospace, uppercase section label — the coach's typewritten index voice.
struct MyoSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .myoStyle(.label)
            .textCase(.uppercase)
            .foregroundStyle(MyoColor.Text.secondary.color)
            .kerning(0.5)
    }
}

/// A single Dossier card: elevated cream sheet, hairline border, radius 14.
struct MyoGroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: MyoTheme.Spacing.md) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MyoTheme.Spacing.md)
        .myoCard()
    }
}

/// Hairline divider used between sub-sections inside a card.
struct MyoHairline: View {
    var body: some View {
        Rectangle()
            .fill(MyoTheme.Colors.ink.opacity(0.08))
            .frame(height: 1)
    }
}

/// Multi-select chip. Selected = ochre (Coach acting on you); unselected = a
/// faint ink wash. Bold weight also carries the selected state so it survives
/// Dynamic Type and reduced-transparency.
struct MyoSelectChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline.weight(isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? MyoColor.Text.primary.color : MyoColor.Text.secondary.color)
                .padding(.horizontal, MyoTheme.Spacing.md)
                .padding(.vertical, MyoTheme.Spacing.sm)
                .background(isSelected ? MyoColor.Surface.selected.color : MyoTheme.Colors.ink.opacity(0.06))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(
                        isSelected ? MyoColor.Action.primary.color : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// Removable free-text tag chip. Tap the × to remove. 44pt tap target.
struct MyoTagChip: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: MyoTheme.Spacing.xs) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MyoColor.Text.primary.color)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(MyoColor.Text.tertiary.color)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(label)")
        }
        .padding(.leading, MyoTheme.Spacing.md)
        .padding(.trailing, MyoTheme.Spacing.xs)
        .padding(.vertical, 2)
        .background(MyoTheme.Colors.ink.opacity(0.06))
        .clipShape(Capsule())
    }
}

/// A rubber-stamp milestone (Pell's material). Brick ink, mono uppercase,
/// slightly rotated and faded so it reads as pressed onto paper, not printed.
/// Milestones only — never UI chrome.
struct MyoStamp: View {
    let line1: String
    var line2: String?
    var rotation: Double = -6

    var body: some View {
        VStack(spacing: 1) {
            Text(line1)
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .kerning(1)
            if let line2 {
                Text(line2)
                    .font(.system(.caption2, design: .monospaced))
                    .kerning(1.5)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(MyoColor.redPen)
        .textCase(.uppercase)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(MyoColor.redPen, lineWidth: 2)
                .opacity(0.85)
        )
        .rotationEffect(.degrees(rotation))
        .opacity(0.9)
        .accessibilityElement(children: .combine)
    }
}

/// Label + trailing value row, min 44pt tall.
struct MyoValueRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(label)
                .myoStyle(.body)
                .foregroundStyle(MyoColor.Text.primary.color)
            Spacer(minLength: MyoTheme.Spacing.md)
            trailing
        }
        .frame(minHeight: 44)
    }
}
