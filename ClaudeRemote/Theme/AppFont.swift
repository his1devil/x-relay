import SwiftUI
import UIKit
import CoreText

/// Typography for the design: `Hanken Grotesk` (sans) + `JetBrains Mono` (mono),
/// both bundled under `Resources/Fonts` and registered via `UIAppFonts`.
///
/// Hanken Grotesk ships as a single variable font, so sans weights are pulled
/// off its `wght` axis through a CoreText variation; JetBrains Mono ships as
/// discrete static weights selected by PostScript name.
enum AppFont {
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(hankenUIFont(size: size, weight: numericWeight(weight)))
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(monoPostScriptName(weight), fixedSize: size)
    }

    // UIKit variants (for the UITextView-backed command composer).
    static func uiSans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> UIFont {
        hankenUIFont(size: size, weight: numericWeight(weight))
    }

    static func uiMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> UIFont {
        UIFont(name: monoPostScriptName(weight), size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: Hanken Grotesk variable axis

    private static let wghtAxis = 0x77676874  // 'wght'

    private static func hankenUIFont(size: CGFloat, weight: CGFloat) -> UIFont {
        let descriptor = UIFontDescriptor(fontAttributes: [
            .name: "HankenGrotesk-Regular",
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wghtAxis: weight],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func numericWeight(_ weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight: return 100
        case .thin: return 200
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }

    // MARK: JetBrains Mono static weights

    private static func monoPostScriptName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "JetBrainsMono-Bold"
        case .semibold: return "JetBrainsMono-SemiBold"
        case .medium: return "JetBrainsMono-Medium"
        default: return "JetBrainsMono-Regular"
        }
    }
}
