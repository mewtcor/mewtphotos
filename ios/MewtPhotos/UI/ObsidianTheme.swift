// Obsidian Glass Bento visual system for Mewt Photos.
// Pure SwiftUI; must never import Photos or PhotosUI (enforced by ci.yml).
import SwiftUI

// MARK: - Accent Theme

public enum MewtAccent: String, CaseIterable, Identifiable {
    case cyan
    case amber

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cyan: return "Cyan"
        case .amber: return "Amber"
        }
    }

    public var color: Color {
        switch self {
        case .cyan: return Color(hex: 0x38BDF8)
        case .amber: return Color(hex: 0xF59E0B)
        }
    }

    public var foreground: Color {
        switch self {
        case .cyan: return Color(hex: 0x04121C)
        case .amber: return Color(hex: 0x1C1102)
        }
    }

    public var softFill: Color {
        color.opacity(0.14)
    }

    public var glow: Color {
        color.opacity(0.24)
    }
}

// MARK: - Obsidian Palette & Motion

public enum ObsidianPalette {
    public static let background = Color(hex: 0x0A0A0F)
    public static let surface = Color.white.opacity(0.04)
    public static let surfaceHover = Color.white.opacity(0.07)
    public static let surfaceSolid = Color(hex: 0x12121A)
    public static let sheetBackground = Color(hex: 0x14141D)
    public static let border = Color.white.opacity(0.08)
    public static let borderStrong = Color.white.opacity(0.14)

    public static let textPrimary = Color(hex: 0xF8FAFC)
    public static let textSecondary = Color(hex: 0x94A3B8)
    public static let textMuted = Color(hex: 0x64748B)

    public static let ok = Color(hex: 0x34D399)
    public static let okSoft = Color(hex: 0x34D399).opacity(0.12)
    public static let warn = Color(hex: 0xFBBF24)
    public static let warnSoft = Color(hex: 0xFBBF24).opacity(0.12)
    public static let err = Color(hex: 0xFB7185)
    public static let errSoft = Color(hex: 0xFB7185).opacity(0.12)

    public static let smoothCurve = Animation.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.30)
}

public extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Background & Glass Card Surfaces

public struct ObsidianBackground: View {
    let accent: MewtAccent

    public init(accent: MewtAccent) {
        self.accent = accent
    }

    public var body: some View {
        ZStack {
            ObsidianPalette.background.ignoresSafeArea()
            RadialGradient(
                colors: [accent.glow, .clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 280
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

public struct GlassCard<Content: View>: View {
    let activeGlow: Color?
    let cornerRadius: CGFloat
    let padding: CGFloat
    @ViewBuilder let content: () -> Content

    public init(
        activeGlow: Color? = nil,
        cornerRadius: CGFloat = 20,
        padding: CGFloat = 16,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.activeGlow = activeGlow
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(ObsidianPalette.surface)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.28)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        activeGlow != nil ? Color.white.opacity(0.12) : ObsidianPalette.border,
                        lineWidth: 1
                    )
            )
            .shadow(color: activeGlow ?? .clear, radius: 22, x: 0, y: 10)
    }
}

// MARK: - Quick Action Pill

public struct QuickActionPill: View {
    let title: String
    let systemImage: String
    let accent: MewtAccent
    let isPrimary: Bool
    let isDisabled: Bool
    let action: () -> Void

    public init(
        title: String,
        systemImage: String,
        accent: MewtAccent,
        isPrimary: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.isPrimary = isPrimary
        self.isDisabled = isDisabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: isPrimary ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .foregroundStyle(isPrimary ? accent.foreground : ObsidianPalette.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isPrimary ? accent.color : ObsidianPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isPrimary ? .clear : ObsidianPalette.border, lineWidth: 1)
            )
            .shadow(color: isPrimary ? accent.glow : .clear, radius: 14, x: 0, y: 6)
            .opacity(isDisabled ? 0.35 : 1.0)
        }
        .buttonStyle(ScalePressButtonStyle())
        .disabled(isDisabled)
    }
}

public struct ScalePressButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(ObsidianPalette.smoothCurve, value: configuration.isPressed)
    }
}

// MARK: - Radial Coverage Ring

public struct RadialCoverageRing: View {
    let progress: Double // 0.0 ... 1.0
    let accent: MewtAccent
    let known: Bool

    public init(progress: Double, accent: MewtAccent, known: Bool = true) {
        self.progress = min(max(progress, 0), 1)
        self.accent = accent
        self.known = known
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 7)

            Circle()
                .trim(from: 0, to: known ? progress : 0)
                .stroke(
                    accent.color,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: accent.glow, radius: 8)
                .animation(ObsidianPalette.smoothCurve, value: progress)

            VStack(spacing: 2) {
                Text(known ? "\(Int((progress * 100).rounded()))%" : "—")
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(ObsidianPalette.textPrimary)
                Text("SYNCED")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(ObsidianPalette.textMuted)
            }
        }
        .frame(width: 92, height: 92)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(known ? "\(Int((progress * 100).rounded())) percent synced" : "Coverage not checked yet")
    }
}

// MARK: - Transfer Rate Sparkline

public struct TransferSparkline: View {
    let samples: [Double]
    let accent: MewtAccent

    public init(samples: [Double], accent: MewtAccent) {
        self.samples = samples
        self.accent = accent
    }

    public var body: some View {
        GeometryReader { geo in
            let vals = samples.isEmpty ? [0.0, 0.0] : samples
            let maxVal = max(vals.max() ?? 10, 10)
            let minVal = min(vals.min() ?? 0, 0)
            let range = max(maxVal - minVal, 1)
            let w = geo.size.width
            let h = geo.size.height

            let points: [CGPoint] = vals.enumerated().map { idx, v in
                let x = vals.count > 1 ? CGFloat(idx) / CGFloat(vals.count - 1) * w : w
                let y = h - CGFloat((v - minVal) / range) * (h - 6) - 3
                return CGPoint(x: x, y: y)
            }

            ZStack {
                Path { path in
                    guard let first = points.first, let last = points.last else { return }
                    path.move(to: CGPoint(x: first.x, y: h))
                    for pt in points { path.addLine(to: pt) }
                    path.addLine(to: CGPoint(x: last.x, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [accent.color.opacity(0.30), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for pt in points.dropFirst() { path.addLine(to: pt) }
                }
                .stroke(accent.color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                if let last = points.last {
                    Circle()
                        .fill(accent.color)
                        .frame(width: 6, height: 6)
                        .position(last)
                        .shadow(color: accent.color, radius: 5)
                }
            }
        }
        .frame(height: 36)
    }
}

// MARK: - Floating Glassmorphic Dock

public enum MewtTab: String, CaseIterable, Identifiable {
    case backup
    case library
    case server

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .backup: return "Backup"
        case .library: return "Library"
        case .server: return "Server"
        }
    }

    public var icon: String {
        switch self {
        case .backup: return "square.grid.2x2"
        case .library: return "photo.on.rectangle.angled"
        case .server: return "server.rack"
        }
    }
}

public struct FloatingGlassDock: View {
    @Binding var selectedTab: MewtTab
    let accent: MewtAccent

    public init(selectedTab: Binding<MewtTab>, accent: MewtAccent) {
        self._selectedTab = selectedTab
        self.accent = accent
    }

    public var body: some View {
        HStack(spacing: 4) {
            ForEach(MewtTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(ObsidianPalette.smoothCurve) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                        Text(tab.title)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? ObsidianPalette.textPrimary : ObsidianPalette.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.08) : .clear)
                    )
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule()
                                .fill(accent.color)
                                .frame(width: 18, height: 2.5)
                                .shadow(color: accent.color, radius: 6)
                                .offset(y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(ObsidianPalette.surfaceSolid.opacity(0.84))
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, x: 0, y: 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
