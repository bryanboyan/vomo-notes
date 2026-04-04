import SwiftUI

#if os(watchOS)
extension Color {
    static let obsidianPurple = Color(red: 0.486, green: 0.227, blue: 0.929)
    static let cardBackground = Color(white: 0.11)
    static let cardShadow = Color.black.opacity(0.08)
}
#else
extension Color {
    static let obsidianPurple = Color(light: .init(hex: 0x7C3AED), dark: .init(hex: 0xA78BFA))
    static let cardBackground = Color(light: .init(hex: 0xF5F5F7), dark: .init(hex: 0x1C1C1E))
    static let cardShadow = Color.black.opacity(0.08)
}

extension UIColor {
    convenience init(hex: UInt, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha
        )
    }
}

extension Color {
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}
#endif
