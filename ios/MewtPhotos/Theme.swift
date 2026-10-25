// The look of the app: colors, cards, buttons and small building blocks shared by every screen. Dark only,
// deep navy surfaces with a violet accent. Pure SwiftUI; it must not import Photos (see ci.yml).
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Theme {
    static let background = Color(hex: 0x0B0D1A)
    static let card = Color(hex: 0x151829)
    static let field = Color(hex: 0x1E2236)
    static let border = Color.white.opacity(0.08)
    static let text = Color(hex: 0xF5F6FA)
    static let muted = Color(hex: 0x9AA3B8)
    static let accent = Color(hex: 0xA78BFA)
    static let cyan = Color(hex: 0x22D3EE)
    static let good = Color(hex: 0x34D399)
    static let warn = Color(hex: 0xFBBF24)
    static let bad = Color(hex: 0xF87171)
    /// White text on this reads at 5:1 or better across the whole gradient.
    static let gradient = LinearGradient(colors: [Color(hex: 0x7C3AED), Color(hex: 0x4F46E5)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let radius: CGFloat = 20
}

/// A scrolling screen on the app background. Every screen is one of these holding panels.
struct Screen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background.ignoresSafeArea())
    }
}

/// A titled group of rows on a rounded card.
struct Panel<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.border))
        }
    }
}

extension View {
    /// The look of a primary action: a full-width violet gradient.
    func primaryLabel() -> some View {
        self.font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    func fieldStyle() -> some View {
        self.padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(Theme.text)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .primaryLabel()
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = Theme.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
    static var danger: SecondaryButtonStyle { SecondaryButtonStyle(tint: Theme.bad) }
}

/// A small tinted rounded square holding an SF Symbol.
struct IconBadge: View {
    let systemName: String
    var tint: Color = Theme.accent
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.47, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row that opens another screen. Use inside a Panel with NavigationLink.
struct NavRow: View {
    let title: String
    let systemName: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: systemName, tint: tint)
            Text(title)
                .font(.body)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// A coloured dot and a word. Colour is never the only signal: the text says the same thing.
struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(text).font(.footnote.weight(.semibold)).foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// A message with an icon: errors, notices and warnings.
struct Callout: View {
    let text: String
    var systemName: String = "exclamationmark.triangle.fill"
    var tint: Color = Theme.bad

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemName)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A caption above a field, so the field is never identified by its placeholder alone.
struct FieldLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.muted)
    }
}

/// A big number with a small label, for run totals.
struct StatTile: View {
    let value: Int
    let label: String
    var tint: Color = Theme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A hairline between rows inside a Panel.
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }
}
