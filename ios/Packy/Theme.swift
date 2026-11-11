import SwiftUI

/// Everyday screens use the calm workbench surfaces (warm gray ground, white cards).
/// Action blue comes from the AppIcon field. Cream is login-only.
/// Status colours also differ in lightness so they never rely on hue alone.
enum Theme {
    static let ground = Color(hex: 0xF4F3EF)
    static let card = Color.white
    static let border = Color(hex: 0xE4E2DC)
    static let divider = Color(hex: 0xEEEDE8)
    static let track = Color(hex: 0xDCDAD3)
    static let ink = Color(hex: 0x16181D)
    static let body = Color(hex: 0x3A3D44)
    static let secondary = Color(hex: 0x5C6068)
    static let night = Color(hex: 0x0F1115)

    /// Field top of the AppIcon, RGB(66, 81, 228).
    static let brand = Color(hex: 0x4251E4)
    /// Field bottom of the AppIcon, RGB(32, 31, 144). Login gradient only.
    static let brandDeep = Color(hex: 0x201F90)
    /// Bottom of the login gradient. Darker than the carton blue so the LoginMark's sides stay visible.
    static let brandNight = Color(hex: 0x0E0D4A)
    /// Cream interior of the carton. Login titles, labels, and Accedi only.
    static let cream = Color(hex: 0xFDEED1)

    static let accent = brand
    static let accentSoft = Color(hex: 0xE5E7FB)
    static let success = Color(hex: 0x0B7A47)
    static let successInk = Color(hex: 0x0B6B3E)
    static let successSoft = Color(hex: 0xE3F3EA)
    static let warning = Color(hex: 0x8A4500)
    static let warningSoft = Color(hex: 0xFDEFD9)
    static let danger = Color(hex: 0xC1232B)
    static let dangerSoft = Color(hex: 0xFBE4E5)

    /// Big counts and headings.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Product codes, so MS001 and MS002 never blur together.
    static func code(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension View {
    func card(border: Color = Theme.border, width: CGFloat = 1, radius: CGFloat = 20) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(border, lineWidth: width))
    }
}

struct Chip: View {
    let text: String
    var foreground: Color = Theme.successInk
    var background: Color = Theme.successSoft

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
    }
}

/// A product's size, set apart as a strong badge because size is where lookalikes differ.
struct SizeBadge: View {
    let size: String
    var strong = true
    var color: Color = Theme.ink

    var body: some View {
        Text(size)
            .font(.body.weight(.bold))
            .foregroundStyle(strong ? .white : Theme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(strong ? color : Theme.divider, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    var foreground: Color = .white
    var height: CGFloat = 56
    /// On the night camera card a disabled button recedes into the dark instead of turning light gray.
    var onDark = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? foreground : (onDark ? .white.opacity(0.45) : Theme.secondary))
            .frame(maxWidth: .infinity, minHeight: height)
            .background(isEnabled ? color : (onDark ? .white.opacity(0.12) : Theme.track), in: RoundedRectangle(cornerRadius: 16))
            .animation(.easeOut(duration: 0.2), value: isEnabled)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: filled ? 56 : 48)
            .background(filled ? Theme.divider : .clear, in: RoundedRectangle(cornerRadius: 16))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A plain progress bar. Works the same for 2 units or 20.
struct ProgressBar: View {
    let done: Int
    let total: Int
    var color: Color = Theme.success
    var empty: Color = Theme.track
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(empty)
                Capsule().fill(color)
                    .frame(width: total > 0 ? geo.size.width * CGFloat(min(done, total)) / CGFloat(total) : 0)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.25), value: done)
        .accessibilityElement()
        .accessibilityLabel("\(done) di \(total)")
    }
}

struct FixtureBanner: View {
    var body: some View {
        Label(PackingFlow.sampleModeShort, systemImage: "testtube.2")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.warning)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Theme.warningSoft, in: Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(PackingFlow.sampleMode)
    }
}

/// A compact notice: one bold line, and at most two lines of detail. Several can stack without pushing the work off screen.
struct Notice: View {
    let title: String
    var detail: String?
    var icon = "exclamationmark.circle.fill"
    var color: Color = Theme.danger
    var soft: Color = Theme.dangerSoft

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.footnote.weight(.semibold))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.semibold))
                if let detail {
                    Text(detail).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(soft, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
