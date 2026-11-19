import SwiftUI

enum Theme {
    static let background = Color(hex: 0x08040F)
    static let surface = Color(hex: 0x150B2E)
    static let primary = Color(hex: 0x7C3AED)
    static let primaryLight = Color(hex: 0xA855F7)
    static let cyan = Color(hex: 0x22D3EE)
    static let success = Color(hex: 0x34D399)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xF87171)
    static let blue = Color(hex: 0x60A5FA)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.64)
    static let textTertiary = Color.white.opacity(0.36)

    static let cornerRadius: CGFloat = 22
    static let contentMaxWidth: CGFloat = 900

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x0B0618), Color(hex: 0x1A0B33), Color(hex: 0x08040F)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [primary, primaryLight], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func accent(_ hex: UInt32) -> Color {
        Color(hex: hex)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
