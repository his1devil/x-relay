import SwiftUI

/// Discord-style palette transcribed verbatim from the `Claude Remote.dc.html`
/// design component (the `theme(mode)` token maps). Two modes: dark + light.
struct Theme {
    // surfaces
    let screen: Color
    let card: Color
    let codebg: Color
    let input: Color
    let field: Color
    // text
    let ink: Color
    let sub: Color
    let muted: Color
    let faint: Color
    let white: Color
    // lines
    let border: Color
    let divider: Color
    // brand / status
    let blurple: Color
    let claude: Color
    let green: Color
    let greenText: Color
    let red: Color
    let gold: Color
    // diff
    let addText: Color
    let delText: Color
    let addBg: Color
    let delBg: Color
    // buttons
    let plusBtn: Color
    let btnSecondary: Color
    let btnSecondaryInk: Color

    let isDark: Bool

    static let dark = Theme(
        screen: Color(hex: 0x313338),
        card: Color(hex: 0x2b2d31),
        codebg: Color(hex: 0x1e1f22),
        input: Color(hex: 0x383a40),
        field: Color(hex: 0x383a40),
        ink: Color(hex: 0xdbdee1),
        sub: Color(hex: 0xb5bac1),
        muted: Color(hex: 0x949ba4),
        faint: Color(hex: 0x80848e),
        white: Color(hex: 0xf2f3f5),
        border: Color(hex: 0x26272b),
        divider: Color.white.opacity(0.07),
        blurple: Color(hex: 0x5865f2),
        claude: Color(hex: 0xe08a66),
        green: Color(hex: 0x248046),
        greenText: Color(hex: 0x3ba55d),
        red: Color(hex: 0xda373c),
        gold: Color(hex: 0xe0a032),
        addText: Color(hex: 0x6bdc8e),
        delText: Color(hex: 0xf17a82),
        addBg: Color(red: 59 / 255, green: 165 / 255, blue: 93 / 255).opacity(0.10),
        delBg: Color(red: 218 / 255, green: 55 / 255, blue: 60 / 255).opacity(0.09),
        plusBtn: Color(hex: 0x4e5058),
        btnSecondary: Color(hex: 0x4e5058),
        btnSecondaryInk: Color(hex: 0xffffff),
        isDark: true
    )

    static let light = Theme(
        screen: Color(hex: 0xffffff),
        card: Color(hex: 0xf2f3f5),
        codebg: Color(hex: 0xf0f1f3),
        input: Color(hex: 0xebedef),
        field: Color(hex: 0xe3e5e8),
        ink: Color(hex: 0x313338),
        sub: Color(hex: 0x4e5058),
        muted: Color(hex: 0x5c5e66),
        faint: Color(hex: 0x80848e),
        white: Color(hex: 0x060607),
        // Light borders were nearly invisible against white cards (e3e5e8 on
        // f2f3f5): chips, the search field and the segmented control read as
        // borderless. Two shades darker keeps them quiet but legible.
        border: Color(hex: 0xc8ccd2),
        divider: Color(red: 6 / 255, green: 6 / 255, blue: 7 / 255).opacity(0.14),
        blurple: Color(hex: 0x5865f2),
        claude: Color(hex: 0xb0512f),
        green: Color(hex: 0x248046),
        greenText: Color(hex: 0x1a7f37),
        red: Color(hex: 0xd22d39),
        gold: Color(hex: 0xb6892b),
        addText: Color(hex: 0x1a7f37),
        delText: Color(hex: 0xcf222e),
        addBg: Color(red: 46 / 255, green: 160 / 255, blue: 67 / 255).opacity(0.14),
        delBg: Color(red: 207 / 255, green: 34 / 255, blue: 46 / 255).opacity(0.11),
        plusBtn: Color(hex: 0xdbdee1),
        btnSecondary: Color(hex: 0xe0e1e5),
        btnSecondaryInk: Color(hex: 0x4e5058),
        isDark: false
    )
}

enum ThemeMode: String {
    case dark, light
    var theme: Theme { self == .dark ? .dark : .light }
}

// MARK: - Environment injection

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Color(hex:)

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: 1
        )
    }
}
