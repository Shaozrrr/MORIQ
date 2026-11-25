import AppKit
import SwiftUI

// MARK: - Apple-Native Liquid Glass Design System (Muse + MORIQ Sapphire/Neutral)

enum LiquidGlassPalette {
    static let sapphire = Color(red: 37.0 / 255.0, green: 99.0 / 255.0, blue: 1.0)
    static let sapphireLight = Color(red: 96.0 / 255.0, green: 165.0 / 255.0, blue: 250.0 / 255.0)

    static func sapphireSoft(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0).opacity(0.22)
            : Color(red: 37.0 / 255.0, green: 99.0 / 255.0, blue: 1.0).opacity(0.11)
    }

    static func inkPrimary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 248.0 / 255.0, green: 250.0 / 255.0, blue: 252.0 / 255.0)
            : Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0)
    }

    static func inkSecondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 203.0 / 255.0, green: 213.0 / 255.0, blue: 225.0 / 255.0).opacity(0.82)
            : Color(red: 51.0 / 255.0, green: 65.0 / 255.0, blue: 85.0 / 255.0).opacity(0.84)
    }

    static func inkTertiary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 148.0 / 255.0, green: 163.0 / 255.0, blue: 184.0 / 255.0).opacity(0.68)
            : Color(red: 71.0 / 255.0, green: 85.0 / 255.0, blue: 105.0 / 255.0).opacity(0.66)
    }

    static func track(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.14)
            : Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.09)
    }

    static func divider(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.10)
            : Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.08)
    }

    static func cpuStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 226.0 / 255.0, green: 232.0 / 255.0, blue: 240.0 / 255.0)
            : Color(red: 30.0 / 255.0, green: 41.0 / 255.0, blue: 59.0 / 255.0)
    }
}

/// Real AppKit vibrancy backdrop that refracts desktop wallpaper behind floating panels.
struct LiquidBackdropBlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

struct LiquidGlassPanelModifier: ViewModifier {
    let cornerRadius: CGFloat
    var strong: Bool = false
    var behindWindow: Bool = true
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                ZStack {
                    LiquidBackdropBlurView(
                        material: scheme == .dark ? .hudWindow : .popover,
                        blendingMode: behindWindow ? .behindWindow : .withinWindow
                    )
                    LinearGradient(
                        colors: scheme == .dark
                            ? [
                                Color(red: 26.0 / 255.0, green: 31.0 / 255.0, blue: 44.0 / 255.0).opacity(strong ? 0.84 : 0.74),
                                Color(red: 14.0 / 255.0, green: 17.0 / 255.0, blue: 25.0 / 255.0).opacity(strong ? 0.88 : 0.78)
                            ]
                            : [
                                Color.white.opacity(strong ? 0.88 : 0.78),
                                Color(red: 244.0 / 255.0, green: 247.0 / 255.0, blue: 252.0 / 255.0).opacity(strong ? 0.82 : 0.72)
                            ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    // Optical top specular refraction sheen
                    LinearGradient(
                        colors: [
                            Color.white.opacity(scheme == .dark ? 0.12 : 0.55),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                }
                .clipShape(shape)
            }
            .overlay {
                // Fresnel multi-stop specular rim
                shape.strokeBorder(
                    LinearGradient(
                        colors: scheme == .dark
                            ? [Color.white.opacity(0.32), Color.white.opacity(0.08), Color.white.opacity(0.18)]
                            : [Color.white.opacity(0.95), Color.black.opacity(0.06), Color.white.opacity(0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
                .allowsHitTesting(false)
            }
    }
}

struct LiquidGlassTileModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var active: Bool = false
    var interactive: Bool = true
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if active {
                    LinearGradient(
                        colors: [
                            Color(red: 37.0 / 255.0, green: 99.0 / 255.0, blue: 1.0),
                            Color(red: 59.0 / 255.0, green: 130.0 / 255.0, blue: 246.0 / 255.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(shape)
                } else {
                    LinearGradient(
                        colors: scheme == .dark
                            ? [
                                Color.white.opacity(hovered && interactive ? 0.13 : 0.09),
                                Color.white.opacity(hovered && interactive ? 0.07 : 0.045)
                            ]
                            : [
                                Color.white.opacity(hovered && interactive ? 0.96 : 0.86),
                                Color(red: 248.0 / 255.0, green: 250.0 / 255.0, blue: 253.0 / 255.0).opacity(hovered && interactive ? 0.88 : 0.74)
                            ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(shape)
                }
            }
            .overlay {
                shape.strokeBorder(
                    active
                        ? Color.white.opacity(0.36)
                        : (scheme == .dark
                            ? Color.white.opacity(hovered && interactive ? 0.24 : 0.13)
                            : Color.white.opacity(0.92)),
                    lineWidth: 0.9
                )
                .allowsHitTesting(false)
            }
            .shadow(
                color: active
                    ? LiquidGlassPalette.sapphire.opacity(0.26)
                    : Color.black.opacity(scheme == .dark ? 0.24 : 0.05),
                radius: hovered && interactive ? 10 : 6,
                x: 0,
                y: hovered && interactive ? 4 : 2
            )
            .onHover { value in
                guard interactive else { return }
                withAnimation(.easeOut(duration: 0.15)) { hovered = value }
            }
    }
}

struct LiquidGlassWellModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                (scheme == .dark
                    ? Color.white.opacity(0.055)
                    : Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(0.045)),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.045),
                    lineWidth: 0.65
                )
                .allowsHitTesting(false)
            }
    }
}

struct LiquidGlassPillModifier: ViewModifier {
    var selected: Bool = false
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                Capsule(style: .continuous).fill(
                    selected
                        ? (scheme == .dark ? Color.white.opacity(0.17) : Color.white.opacity(0.95))
                        : (scheme == .dark ? Color.white.opacity(0.09) : Color.white.opacity(0.76))
                )
            )
            .overlay {
                Capsule(style: .continuous).strokeBorder(
                    scheme == .dark ? Color.white.opacity(selected ? 0.28 : 0.14) : Color.black.opacity(0.06),
                    lineWidth: 0.7
                )
                .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(selected ? (scheme == .dark ? 0.22 : 0.06) : 0), radius: 4, x: 0, y: 1.5)
    }
}

extension View {
    func liquidGlassPanel(cornerRadius: CGFloat = 24, strong: Bool = false, behindWindow: Bool = true) -> some View {
        modifier(LiquidGlassPanelModifier(cornerRadius: cornerRadius, strong: strong, behindWindow: behindWindow))
    }

    func liquidGlassTile(cornerRadius: CGFloat = 18, active: Bool = false, interactive: Bool = true) -> some View {
        modifier(LiquidGlassTileModifier(cornerRadius: cornerRadius, active: active, interactive: interactive))
    }

    func liquidGlassWell(cornerRadius: CGFloat = 14) -> some View {
        modifier(LiquidGlassWellModifier(cornerRadius: cornerRadius))
    }

    func liquidGlassPill(selected: Bool = false) -> some View {
        modifier(LiquidGlassPillModifier(selected: selected))
    }
}

// MARK: - Sculpted Machined Titanium Apple Silicon Die Plaque

struct MachinedAppleDieBadge: View {
    let chipShort: String
    let coreShort: String
    var size: CGFloat = 42

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
        VStack(spacing: 1.5) {
            HStack(spacing: 2) {
                Image(systemName: "apple.logo")
                    .font(.system(size: size * 0.23, weight: .semibold))
                Text(chipShort)
                    .font(.system(size: size * 0.25, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            Text(coreShort)
                .font(.system(size: max(7, size * 0.175), weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(Color(red: 147.0 / 255.0, green: 197.0 / 255.0, blue: 253.0 / 255.0).opacity(0.92))
        }
        .frame(width: size, height: size)
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 43.0 / 255.0, green: 49.0 / 255.0, blue: 64.0 / 255.0),
                        Color(red: 22.0 / 255.0, green: 26.0 / 255.0, blue: 36.0 / 255.0),
                        Color(red: 11.0 / 255.0, green: 14.0 / 255.0, blue: 20.0 / 255.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                LinearGradient(
                    colors: [Color.white.opacity(0.22), .clear],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            }
            .clipShape(shape)
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [Color.white.opacity(0.42), Color.white.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: 0.9
            )
        }
        .shadow(color: .black.opacity(0.24), radius: 5, x: 0, y: 3)
    }
}

// MARK: - Apple WidgetKit Circular Ring Gauge

struct AppleRingGauge<Center: View>: View {
    let percent: Double
    var size: CGFloat = 42
    var lineWidth: CGFloat = 4.2
    var tint: Color = LiquidGlassPalette.sapphire
    @ViewBuilder var center: () -> Center
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let clamped = min(1.0, max(0.02, percent / 100.0))
        ZStack {
            Circle()
                .stroke(LiquidGlassPalette.track(scheme), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Multi-Segment macOS Memory / Storage Bar

struct MultiSegmentTelemetryBar: View {
    let primaryFraction: Double
    let secondaryFraction: Double
    var primaryColor: Color = LiquidGlassPalette.sapphire
    var secondaryColor: Color = LiquidGlassPalette.sapphireLight
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let f1 = min(1, max(0.03, primaryFraction))
            let f2 = min(max(0, 1 - f1), max(0, secondaryFraction))
            HStack(spacing: 1.5) {
                Capsule()
                    .fill(primaryColor)
                    .frame(width: max(3, w * f1))
                if f2 > 0.015 {
                    Capsule()
                        .fill(secondaryColor)
                        .frame(width: max(2, w * f2))
                }
                Spacer(minLength: 0)
            }
            .padding(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LiquidGlassPalette.track(scheme), in: Capsule())
        }
        .frame(height: 6)
    }
}

// MARK: - 120Hz Control Center Continuous Capsule & Pillar Sliders

struct ControlCenterSliderCapsule: View {
    let symbol: String
    let value: Double // 0...1
    var minimum: Double = 0.0
    var vertical: Bool = false
    var label: String? = nil
    let onChange: (Double, Bool) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let clamped = min(1.0, max(0.0, value))
            ZStack(alignment: vertical ? .bottom : .leading) {
                RoundedRectangle(cornerRadius: vertical ? 15 : 13, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.065))

                RoundedRectangle(cornerRadius: vertical ? 15 : 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                LiquidGlassPalette.sapphire.opacity(0.92),
                                LiquidGlassPalette.sapphireLight.opacity(0.88)
                            ],
                            startPoint: vertical ? .bottom : .leading,
                            endPoint: vertical ? .top : .trailing
                        )
                    )
                    .frame(
                        width: vertical ? nil : max(0, geo.size.width * clamped),
                        height: vertical ? max(0, geo.size.height * clamped) : nil
                    )

                if vertical {
                    VStack {
                        Text("\(Int((clamped * 100).rounded()))%")
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(clamped > 0.84 ? .white : LiquidGlassPalette.inkSecondary(scheme))
                            .padding(.top, 7)
                        Spacer()
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(clamped > 0.18 ? .white : LiquidGlassPalette.inkPrimary(scheme))
                            .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(clamped > 0.16 ? .white : LiquidGlassPalette.inkPrimary(scheme))
                        if let label {
                            Text(label)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1)
                                .foregroundStyle(clamped > 0.42 ? .white : LiquidGlassPalette.inkPrimary(scheme))
                        }
                        Spacer(minLength: 2)
                        Text("\(Int((clamped * 100).rounded()))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(clamped > 0.88 ? .white : LiquidGlassPalette.inkSecondary(scheme))
                    }
                    .padding(.horizontal, 9)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: vertical ? 15 : 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: vertical ? 15 : 13, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.7), lineWidth: 0.6)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let raw = vertical
                            ? 1.0 - Double(drag.location.y / max(1, geo.size.height))
                            : Double(drag.location.x / max(1, geo.size.width))
                        onChange(min(1.0, max(minimum, raw)), false)
                    }
                    .onEnded { drag in
                        let raw = vertical
                            ? 1.0 - Double(drag.location.y / max(1, geo.size.height))
                            : Double(drag.location.x / max(1, geo.size.width))
                        onChange(min(1.0, max(minimum, raw)), true)
                    }
            )
        }
    }
}

// MARK: - Recessed Frosted Liquid Glass Empty DIY Socket

struct RecessedGlassEmptySlot: View {
    var highlighted: Bool = false
    var action: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Button {
            action?()
        } label: {
            ZStack {
                shape.fill(
                    highlighted
                        ? LiquidGlassPalette.sapphireSoft(scheme)
                        : (scheme == .dark
                            ? Color.white.opacity(hovered ? 0.06 : 0.032)
                            : Color(red: 15.0 / 255.0, green: 23.0 / 255.0, blue: 42.0 / 255.0).opacity(hovered ? 0.055 : 0.028))
                )
                shape.strokeBorder(
                    highlighted
                        ? LiquidGlassPalette.sapphire.opacity(0.65)
                        : (hovered
                            ? LiquidGlassPalette.sapphire.opacity(0.36)
                            : (scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))),
                    style: StrokeStyle(lineWidth: highlighted ? 1.4 : 0.8, dash: highlighted ? [] : [4, 4])
                )
                Circle()
                    .fill(scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.75))
                    .frame(width: 22, height: 22)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(hovered || highlighted ? LiquidGlassPalette.sapphire : LiquidGlassPalette.inkTertiary(scheme))
                    }
                    .scaleEffect(hovered || highlighted ? 1.08 : 1.0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { v in withAnimation(.easeOut(duration: 0.14)) { hovered = v } }
    }
}
