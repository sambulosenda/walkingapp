import SwiftUI

/// Raw colours from the v2 designs. Shared by the app, the widget extension and the watch app.
/// Screen code should prefer the adaptive `Theme` tokens, which switch for After dark.
enum Palette {
    static let ink = Color(hex: 0x14262B)
    static let ground = Color(hex: 0xF1F2EE)
    static let muted = Color(hex: 0x56666A)
    static let chip = Color(hex: 0xEEF0EC)
    static let rowIdle = Color(hex: 0xF3F4F1)
    static let radioIdle = Color(hex: 0x7B8D91)
    static let grabber = Color(hex: 0xC9CFCC)

    /// "New to you" streets.
    static let fresh = Color(hex: 0xF26A1B)
    /// The walker's position.
    static let you = Color(hex: 0x0A7AFF)
    /// A reported street.
    static let reported = Color(hex: 0xB3261E)
    static let park = Color(hex: 0xD5E6CF)
    static let water = Color(hex: 0xCBE1EE)

    // After dark
    static let nightGround = Color(hex: 0x0E1517)
    static let nightSheet = Color(hex: 0x151E21)
    static let nightText = Color(hex: 0xF2F5F6)
    static let nightMuted = Color(hex: 0x9FB0B5)
    static let nightChip = Color(hex: 0x223035)
    static let nightGrabber = Color(hex: 0x3A4A4F)

    // Live Activity and Dynamic Island
    static let activityCard = Color(hex: 0x17343A)
    static let activityMuted = Color(hex: 0xB8C7CA)
    static let activityTrack = Color(hex: 0x2C4A51)
    static let islandTrack = Color(hex: 0x24363A)

    // Watch
    static let watchMuted = Color(hex: 0xC9D4D6)
    static let watchFresh = Color(hex: 0xFF8A45)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension Font {
    /// The rounded numerals used for times, distances and percentages.
    static func rounded(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
