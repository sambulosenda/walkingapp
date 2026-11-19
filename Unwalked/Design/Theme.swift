import SwiftUI
import UIKit

/// Adaptive tokens. Light values are the v2 day screens, dark values the "After dark" screen.
enum Theme {
    static let text = adaptive(light: 0x14262B, dark: 0xF2F5F6)
    static let muted = adaptive(light: 0x56666A, dark: 0x9FB0B5)
    static let ground = adaptive(light: 0xF1F2EE, dark: 0x0E1517)
    static let sheet = adaptive(light: 0xFFFFFF, dark: 0x151E21)
    static let chip = adaptive(light: 0xEEF0EC, dark: 0x223035)
    static let rowIdle = adaptive(light: 0xF3F4F1, dark: 0x1C272B)
    static let rowSelected = adaptive(light: 0xFFFFFF, dark: 0x151E21)
    static let radioIdle = adaptive(light: 0x7B8D91, dark: 0x6F8186)
    static let grabber = adaptive(light: 0xC9CFCC, dark: 0x3A4A4F)
    static let tickIdle = adaptive(light: 0xC9CFCC, dark: 0x3A4A4F)
    /// Primary button fill, and its label colour.
    static let primary = adaptive(light: 0x14262B, dark: 0xF2F5F6)
    static let onPrimary = adaptive(light: 0xFFFFFF, dark: 0x14262B)
    static let glass = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 21 / 255, green: 30 / 255, blue: 33 / 255, alpha: 0.74)
            : UIColor(white: 1, alpha: 0.78)
    })
    static let controlTint = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(red: 20 / 255, green: 38 / 255, blue: 43 / 255, alpha: 0.08)
    })
    /// Streets already walked: dark by day, light at night.
    static let walked = adaptive(light: 0x14262B, dark: 0xEEF2F3)

    static let sheetRadius: CGFloat = 32
    static let rowRadius: CGFloat = 20

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }
}
