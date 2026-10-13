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

/// Opens the You screen. Sits in the top-right corner of every tab — an icon
/// only, no label — so profile and settings stay one tap away without taking
/// a tab.
struct ProfileButton: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        if appModel.hasSession { button }
    }

    private var button: some View {
        Button {
            appModel.showProfile = true
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("You")
        .accessibilityHint("Your profile, goals, memory and account")
    }
}

extension View {
    /// Liquid Glass on iOS 26 (interactive: it lights up and flexes under
    /// your finger); frosted material on older systems. `tint` warms it.
    func myoGlass(tint: Color? = nil, in shape: some Shape = Capsule()) -> some View {
        glassBase(tint: tint, in: shape)
            // Light catching the top edge, fading round the sides…
            .overlay(
                shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.15), .white.opacity(0.5)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1.2
                )
                .allowsHitTesting(false)
            )
            // …and a soft sheen across the upper half.
            .overlay(
                shape.fill(LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0)],
                                          startPoint: .top, endPoint: .center))
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .shadow(color: MyoTheme.Colors.ink.opacity(0.08), radius: 10, y: 4)
    }

    @ViewBuilder
    private func glassBase(tint: Color?, in shape: some Shape) -> some View {
        // compiler(>=6.2) ⇔ Xcode 26 SDK, where Glass exists; CI's older
        // Xcode compiles only the fallback.
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive(), in: shape)
        } else {
            frosted(tint: tint, in: shape)
        }
        #else
        frosted(tint: tint, in: shape)
        #endif
    }

    private func frosted(tint: Color?, in shape: some Shape) -> some View {
        background(.ultraThinMaterial, in: shape)
            .background((tint ?? .clear).opacity(0.35), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.5), lineWidth: 0.75))
    }
}

/// The coach's color: drag along the ribbon for any hue, and along the slim
/// track for soft to vivid. Wherever the coach's body is on screen, it is the
/// preview — it changes as you drag. `swatch` adds a small one for screens
/// without the body.
struct CoachColorPicker: View {
    @Binding var hex: String
    var swatch = false

    @State private var hue: Double = 0
    @State private var vivid: Double = 1
    @State private var dragging = false
    /// The last hex this picker wrote, so outside changes can be told apart.
    @State private var written = ""

    private var name: String { CoachColor.name(hue: hue) }
    private var current: Color { CoachColor.color(hue: hue, vivid: vivid) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: MyoTheme.Spacing.sm) {
                if swatch {
                    Circle()
                        .fill(RadialGradient(colors: [MyoTheme.Colors.cream, current],
                                             center: UnitPoint(x: 0.38, y: 0.32), startRadius: 1, endRadius: 22))
                        .frame(width: 36, height: 36)
                        .overlay(Circle().stroke(MyoColor.hairline, lineWidth: 1))
                        .accessibilityHidden(true)
                }
                Text(name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MyoColor.Text.primary.color)
                    .contentTransition(.opacity)
                    .animation(MyoTheme.Motion.fade, value: name)
                Spacer()
                if hex.uppercased() != CoachColor.defaultHex {
                    roundButton("arrow.uturn.backward", label: "Back to amber") {
                        set(hue: CoachColor.position(of: CoachColor.defaultHex).hue, vivid: 1, animated: true)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                roundButton("dice", label: "Surprise me", action: surprise)
            }
            .animation(MyoTheme.Motion.fade, value: hex.uppercased() == CoachColor.defaultHex)
            ribbon
            HStack(spacing: 10) {
                Text("SOFT").font(.system(.caption2, design: .monospaced).weight(.medium))
                track(height: 22, thumb: 24, fraction: vivid,
                      colors: [CoachColor.color(hue: hue, vivid: 0), CoachColor.color(hue: hue, vivid: 1)]) { vivid = $0 }
                    .accessibilityElement()
                    .accessibilityLabel("Softness")
                    .accessibilityValue(vivid < 0.34 ? "Soft" : vivid < 0.67 ? "Medium" : "Vivid")
                    .accessibilityAdjustableAction { direction in
                        set(hue: hue, vivid: vivid + (direction == .increment ? 0.2 : -0.2), animated: true)
                    }
                Text("VIVID").font(.system(.caption2, design: .monospaced).weight(.medium))
            }
            .foregroundStyle(MyoColor.Text.tertiary.color)
        }
        .onAppear(perform: load)
        .onChange(of: hex) { _, value in
            if value.uppercased() != written { load() }
        }
    }

    private func roundButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MyoColor.Text.secondary.color)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .myoGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var ribbon: some View {
        let colors = stride(from: 0.0, through: 1.0, by: 1.0 / 18).map { CoachColor.color(hue: $0, vivid: vivid) }
        return track(height: 34, thumb: 32, fraction: hue, colors: colors) { value in
            let before = name
            hue = min(value, 0.999)
            if name != before { UISelectionFeedbackGenerator().selectionChanged() }
        }
        .accessibilityElement()
        .accessibilityLabel("Coach's color")
        .accessibilityValue(name)
        .accessibilityAdjustableAction { direction in
            let step = 1.0 / Double(CoachColor.stops.count)
            let next = (hue + (direction == .increment ? step : -step) + 1).truncatingRemainder(dividingBy: 1)
            set(hue: next, vivid: vivid, animated: true)
        }
    }

    /// A capsule of colour with a knob that follows your finger anywhere on it.
    private func track(height: CGFloat, thumb: CGFloat, fraction: Double, colors: [Color],
                       onDrag: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumb, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: height)
                    // A little paper through the colour, so it sits on the page.
                    .overlay(Capsule().fill(MyoTheme.Colors.cream.opacity(0.16)))
                    .overlay(Capsule().stroke(MyoColor.hairline, lineWidth: 1))
                Circle()
                    .fill(current)
                    .overlay(Circle().stroke(MyoTheme.Colors.cream, lineWidth: 3))
                    .overlay(Circle().stroke(MyoTheme.Colors.ink.opacity(0.18), lineWidth: 1).padding(-1))
                    .frame(width: thumb, height: thumb)
                    .scaleEffect(dragging ? 1.18 : 1)
                    .offset(x: usable * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !dragging {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { dragging = true }
                        }
                        onDrag(min(max((drag.location.x - thumb / 2) / usable, 0), 1))
                        write()
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { dragging = false }
                    }
            )
        }
        .frame(height: max(height, thumb) + 8)
    }

    private func surprise() {
        set(hue: Double.random(in: 0..<1), vivid: Double.random(in: 0.45...1), animated: true)
    }

    private func set(hue newHue: Double, vivid newVivid: Double, animated: Bool) {
        withAnimation(animated ? .spring(response: 0.45, dampingFraction: 0.72) : nil) {
            hue = min(max(newHue, 0), 0.999)
            vivid = min(max(newVivid, 0), 1)
        }
        write()
    }

    private func write() {
        let value = CoachColor.hex(hue: hue, vivid: vivid)
        written = value
        hex = value
    }

    private func load() {
        let position = CoachColor.position(of: hex)
        hue = position.hue
        vivid = position.vivid
        written = hex.uppercased()
    }
}
