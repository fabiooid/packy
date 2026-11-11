import SwiftUI

/// Packy's colours come from the AppIcon: the royal-blue field, the carton faces,
/// and the cream and gold interior. Semantic colours exist only where the packing
/// flow already needs them (success, error, disabled). One token per role.
enum Theme {
    /// Field top of the icon, RGB(66, 81, 228). Also the carton's sunlit faces.
    static let brand = Color(hex: 0x4251E4)
    /// Field bottom of the icon, RGB(32, 31, 144).
    static let brandDeep = Color(hex: 0x201F90)
    /// Cream interior of the open carton.
    static let cream = Color(hex: 0xFDEED1)
    /// Gold interior flap of the open carton.
    static let gold = Color(hex: 0xE9BC79)

    static let ground = cream
    static let card = Color.white
    /// One warm line, mixed from cream toward ink. Borders, dividers, and empty tracks.
    static let line = Color(hex: 0xE6D8BF)
    static let border = line
    static let divider = line
    static let track = line

    static let ink = Color(hex: 0x16181D)
    static let secondary = Color(hex: 0x5C6068)
    static let body = ink
    static let night = ink

    static let accent = brand
    static let success = Color(hex: 0x0B7A47)
    static let successSoft = Color(hex: 0xE3F3EA)
    /// Darkened gold, for warning text on cream or gold.
    static let warning = Color(hex: 0x6E4912)
    static let warningSoft = gold
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
    var foreground: Color = Theme.success
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
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? foreground : Theme.secondary)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(isEnabled ? color : Theme.track, in: RoundedRectangle(cornerRadius: 16))
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
        Label(PackingFlow.sampleMode, systemImage: "testtube.2")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.warningSoft, in: RoundedRectangle(cornerRadius: 16))
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
